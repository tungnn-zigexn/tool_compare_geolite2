require 'net/http'
require 'uri'
require 'json'

class SlackNotifierService
  def initialize(webhook_url:, logger:)
    @webhook_url = webhook_url
    @logger = logger
  end

  def send_message(message)
    return if @webhook_url.to_s.empty?

    @logger.info("Sending notification to Slack...")
    uri = URI(@webhook_url)
    req = Net::HTTP::Post.new(uri)
    req.content_type = 'application/json'
    req.body = { 'text' => message }.to_json
    
    req_options = { use_ssl: uri.scheme == 'https', open_timeout: 10, read_timeout: 10 }
    
    begin
      Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
        http.request(req)
      end
      @logger.info("Slack notification sent.")
    rescue StandardError => e
      @logger.error("Failed to send message to Slack: #{e.message}")
    end
  end
end
