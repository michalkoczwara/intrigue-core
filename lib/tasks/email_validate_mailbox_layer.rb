module Intrigue
class EmailValidateMailboxLayerTask < BaseTask
  include Intrigue::Task::Web


  def metadata
    {
      :name => "email_validate_mailbox_layer",
      :pretty_name => "Email Validate via MailboxLayer",
      :authors => ["jcran"],
      :description => "This task validates an email via the MailboxLayer API.",
      :requires_config => [""],
      :references => [],
      :allowed_types => ["EmailAddress"],
      :example_entities => [
        {"type" => "EmailAddress", "attributes" => {"name" => "test@intrigue.io"}}
      ],
      :allowed_options => [],
      :created_types => ["Info"]
    }
  end

  ## Default method, subclasses must override this
  def run
    super

    email_address = _get_entity_attribute "name"
    api_key = _get_global_config "mailbox_layer_apikey"
    uri = "https://apilayer.net/api/check?access_key=#{api_key}&email=#{email_address}&smtp=1&format=1"

    email_validation_results = JSON.parse http_get_body(uri)
    @task_result.logger.log "Got result: #{email_validation_results["status"]}"

=begin
{
  "email":"test@intrigue.io",
  "did_you_mean":"",
  "user":"test",
  "domain":"intrigue.io",
  "format_valid":true,
  "mx_found":true,
  "smtp_check":true,
  "catch_all":null,
  "role":false,
  "disposable":false,
  "free":false,
  "score":0.96
}
=end

    if email_validation_results["smtp_check"]
      _create_entity "Info", email_validation_results.merge({"name" => "Valid Email: #{email_address}"})
    else
      _create_entity "Info", email_validation_results.merge({"name" => "Invalid Email: #{email_address}"})
    end



  end

end
end
