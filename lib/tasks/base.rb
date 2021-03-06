require 'timeout'

module Intrigue
class BaseTask
  include Sidekiq::Worker
  sidekiq_options :queue => :task

  def self.inherited(base)
    TaskFactory.register(base)
  end

  def perform(task_id, handlers, hook_uri=nil)
    #######################
    # Get the Task Result #
    #######################
    @task_result = Intrigue::Model::TaskResult.get task_id
    raise "Unable to find task result by id #{task_id}. Bailing." unless @task_result

    @entity = @task_result.base_entity
    options = @task_result.options
    raise "Unable to find entity. Bailing." unless @entity

    # We need a flag to skip the actual setup, run, cleanup of the task if
    # the caller gave us something broken. We still want to get the final
    #  task result back to the caller though (so no raise). Assume it's good,
    # and check input along the way.
    broken_input_flag = false

    # Do a little logging. Do it for the kids
    @task_result.logger.log "Id: #{task_id}"
    @task_result.logger.log "Entity: #{@entity.type_string}##{@entity.name}"
    #@task_result.logger.log "Options: #{options}"

    ###################
    # Sanity Checking #
    ###################
    allowed_types = self.metadata[:allowed_types]

    # Check to make sure this task can receive an entity of this type
    unless allowed_types.include?(@entity.type_string) || allowed_types.include?("*")
      @task_result.logger.log_error "Unable to call #{self.metadata[:name]} on entity: #{@entity}"
      broken_input_flag = true
    end

    ###########################
    # Setup the task result   #
    ###########################
    @task_result.task_name = metadata[:name]
    @task_result.timestamp_start = Time.now.getutc
    @task_result.id = task_id

    ###################################
    # Perform the setup->run workflow #
    ###################################
    unless broken_input_flag
      # Setup creates the following objects:
      # @user_options - a hash of task options
      # @task_result - the final result to be passed back to the caller
      @task_result.logger.log "Calling setup()"
      if setup(task_id, @entity, options)
        begin
          Timeout.timeout($intrigue_global_timeout) do # 15 minutes should be enough time to hit a class b for a single port w/ masscan
            @task_result.logger.log "Calling run()"
            # Save the task locally
            @task_result.save
            # Run the task, which will update @task_result and @task_result
            run()
            @task_result.logger.log_good "Run complete. Ship it!"
          end
        rescue Timeout::Error
          @task_result.logger.log_error "ERROR! Timed out"
        end
      else
        @task_result.logger.log_error "Setup failed, bailing out!"
      end
    end

    #
    # Handlers!
    #
    # This is currently used from the core-cli load command - both csv and
    # json handlers are passed, and thus generated by the appropriate classes
    # (see lib/report/handlers)
    handlers.each do |handler_type|
      @task_result.logger.log "Processing #{handler_type} handler!"
      begin
        options << {:hook_uri => hook_uri} if handler_type == "webhook"
        handler = HandlerFactory.create_by_type(handler_type)
        response = handler.process(@task_result, options)
      rescue Exception => e
        @task_result.logger.log_error "Unable to process handler #{handler_type}: #{e}\N"
        @task_result.logger.log_error "Got response: #{response}"
      end
    end

    #
    # Mark it complete and save it
    #
    # http://stackoverflow.com/questions/178704/are-unix-timestamps-the-best-way-to-store-timestamps
    @task_result.timestamp_end = Time.now.getutc
    @task_result.complete = true

    @task_result.logger.log "Calling cleanup!"
    cleanup

    @task_result.save
  end

  #########################################################
  # These methods are used to perform work in several steps.
  # they should be overridden by individual tasks, but note that
  # individual tasks must always call super()
  #
  def setup(task_id, entity, user_options)

    # We need to parse options and make sure we're
    # allowed to accept these options. Compare to allowed_options.

    #
    # allowed options is formatted:
    #    [{:name => "count", :type => "Integer", :default => 1 }, ... ]
    #
    # user_options is formatted:
    #    [{"name" => "option name", "value" => "value"}, ...]

    allowed_options = self.metadata[:allowed_options]
    @user_options = []
    if user_options
      #@task_result.logger.log "Got user options list: #{user_options}"
      # for each of the user-supplied options
      user_options.each do |user_option| # should be an array of hashes
        # go through the allowed options
        allowed_options.each do |allowed_option|
          # If we have a match of an allowed option & one of the user-specified options
          if "#{user_option["name"]}" == "#{allowed_option[:name]}"

            ### Match the user option against its specified regex
            if allowed_option[:regex] == "integer"
              #@task_result.logger.log "Regex should match an integer"
              regex = /^-?\d+$/
            elsif allowed_option[:regex] == "boolean"
              #@task_result.logger.log "Regex should match a boolean"
              regex = /(true|false)/
            elsif allowed_option[:regex] == "alpha_numeric"
              #@task_result.logger.log "Regex should match an alpha-numeric string"
              regex = /^[a-zA-Z0-9\_\;\(\)\,\?\.\-\_\/\~\=\ \,\?\*]*$/
            elsif allowed_option[:regex] == "alpha_numeric_list"
              #@task_result.logger.log "Regex should match an alpha-numeric list"
              regex = /^[a-zA-Z0-9\_\;\(\)\,\?\.\-\_\/\~\=\ \,\?\*]*$/
            elsif allowed_option[:regex] == "filename"
              #@task_result.logger.log "Regex should match a filename"
              regex = /(?:\..*(?!\/))+/
            elsif allowed_option[:regex] == "ip_address"
              #@task_result.logger.log "Regex should match an IP Address"
              regex = /^(\s*((([0-9A-Fa-f]{1,4}:){7}([0-9A-Fa-f]{1,4}|:))|(([0-9A-Fa-f]{1,4}:){6}(:[0-9A-Fa-f]{1,4}|((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})|:))|(([0-9A-Fa-f]{1,4}:){5}(((:[0-9A-Fa-f]{1,4}){1,2})|:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})|:))|(([0-9A-Fa-f]{1,4}:){4}(((:[0-9A-Fa-f]{1,4}){1,3})|((:[0-9A-Fa-f]{1,4})?:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){3}(((:[0-9A-Fa-f]{1,4}){1,4})|((:[0-9A-Fa-f]{1,4}){0,2}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){2}(((:[0-9A-Fa-f]{1,4}){1,5})|((:[0-9A-Fa-f]{1,4}){0,3}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){1}(((:[0-9A-Fa-f]{1,4}){1,6})|((:[0-9A-Fa-f]{1,4}){0,4}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(:(((:[0-9A-Fa-f]{1,4}){1,7})|((:[0-9A-Fa-f]{1,4}){0,5}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:)))(%.+)?\s*)|((\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3}))$/
            else
              @task_result.logger.log_error "Unspecified regex for this option #{allowed_option[:name]}"
              @task_result.logger.log_error "FATAL! Unable to continue!"
              return nil
            end

            # Run the regex
            unless regex.match "#{user_option["value"]}"
              @task_result.logger.log_error "Regex didn't match"
              @task_result.logger.log_error "Option #{user_option["name"]} does not match regex: #{regex.to_s} (#{user_option["value"]})!"
              @task_result.logger.log_error "FATAL! Regex didn't match, failing!"
              return nil
            end

            ###
            ### End Regex matching
            ###

            # We have an allowed option, with the right kind of value
            # ...Now set the correct type

            # So things like core-cli are parsing data as strings,
            # and are sending us all of our options as strings. Which sucks. We
            # have to do the explicit conversion to the right type if we want things to go
            # smoothly. I'm sure there's a better way to do this in ruby, but
            # i'm equally sure don't know what it is. We'll fail the task if
            # there's something we can't handle

            if allowed_option[:type] == "Integer"
              # convert to integer
              #@task_result.logger.log "Converting #{user_option["name"]} to an integer"
              user_option["value"] = user_option["value"].to_i
            elsif allowed_option[:type] == "String"
              # do nothing, we can just pass strings through
              #@task_result.logger.log "No need to convert #{user_option["name"]} to a string"
              user_option["value"] = user_option["value"]
            elsif allowed_option[:type] == "Boolean"
              # use our monkeypatched .to_bool method (see initializers)
              #@task_result.logger.log "Converting #{user_option["name"]} to a bool"
              user_option["value"] = user_option["value"].to_bool if user_option["value"].kind_of? String
            else
              # throw an error, we likely have a string we don't know how to cast
              @task_result.logger.log_error "FATAL! Don't know how to handle this option when it's given to us as a string."
              return nil
            end

            # Hurray, we can accept this value
            @user_options << { allowed_option[:name] => user_option["value"] }
          end
        end

      end
      @task_result.logger.log "Options: #{@user_options}"
    else
      @task_result.logger.log "No User options"
    end

    #@task_result.save

  true
  end

  # This method is overridden
  def run
  end

  def cleanup
    @task_result.logger.save
  end
  #
  #########################################################

  # Override this method if the task has external dependencies
  def check_external_dependencies
    true
  end

  private

    # Convenience Method to execute a system command semi-safely
    #  !!!! Don't send anything to this without first whitelisting user input!!!
    def _unsafe_system(command)

      ###                  ###
      ###  XXX - SECURITY  ###
      ###                  ###

      if command =~ /(\||\;|\`)/
        #raise "Illegal character"
        @task_result.logger.log_error "FATAL Illegal character in #{command}"
        return
      end

      `#{command}`
    end

    #
    # This is a helper method, use this to create entities from within tasks
    #
    def _create_entity(type, hash)
      @task_result.logger.log_good "Creating entity: #{type}, #{hash.inspect}"

      # Create the entity, validating the attributes
      #begin

        #xx = eval("Intrigue::Entity::#{type}").create(
        #  :name => hash["name"],
        #  :details => hash
        #)
        #xx.details = hash
        #xx.save

        entity = Intrigue::Model::Entity.create({
                    :type => eval("Intrigue::Entity::#{type}"),
                    :name => hash["name"],
                    :details => {:name => hash["name"]} })
        # Compensating for Datamapper WEIRDNESS
        entity.details = hash
        entity.save

        #binding.pry
      #rescue DataMapper::SaveFailureError => e
      #  @task_result.logger.log_error "Unable to create entity: #{type}, #{hash.inspect}"
      #  @task_result.logger.log_error "ERROR: #{e}"
      #end

      # If we don't get anything back, safe to assume we can't move on
      unless entity
        @task_result.logger.log_error "SKIPPING Unable to verify & save entity: #{type} #{hash}"
        return
      end

      # Add to our result set for this task
      @task_result.add_entity entity

    # return the entity
    entity
    end

    def _canonical_name
      "#{self.metadata[:name]}: #{self.metadata[:version]}"
    end

    def _get_entity_attribute(attrib_name)
      "#{@task_result.base_entity.details[attrib_name]}"
    end

    def _get_global_config(key)
      begin
        $intrigue_config[key]["value"]
      rescue NoMethodError => e
        puts "Error, invalid config key requested (#{key}) #{e}"
      end
    end

    ###
    ### XXX TODO - move this up into the setup method and make it happen automatically
    ###
    def _get_option(name)

      # Start with nothing
      value = nil

      # First, get the default value by cycling through the allowed options
      method = metadata[:allowed_options].each do |allowed_option|
        value = allowed_option[:default] if allowed_option[:name] == name
      end

      # Then, cycle through the user-provided options
      @user_options.each do |user_option|
        value = user_option[name] if user_option[name]
      end

      #@task_result.logger.log "Option configured: #{name}"

    value
    end

end
end
