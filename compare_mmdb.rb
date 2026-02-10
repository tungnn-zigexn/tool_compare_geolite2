require 'fileutils'
require 'dotenv'
require 'maxminddb'
require 'tmpdir'
require 'time'

# Load .env file
Dotenv.load(File.expand_path('.env', __dir__))

require_relative 'shared_utils'
require_relative 'gcs_baseline_downloader'
require_relative 'http_client_service'
require_relative 'tar_extractor_service'
require_relative 'max_mind_downloader_service'
require_relative 'slack_notifier_service'

# Configuration from ENV
GCS_BUCKET = ENV.fetch('GCS_BUCKET', nil)
GCS_OBJECT = ENV.fetch('GCS_OBJECT', 'geolite2/GeoLite2-Country.mmdb')
MAXMIND_LICENSE_KEY = ENV.fetch('MAXMIND_LICENSE_KEY', nil)
MAXMIND_ACCOUNT_ID = ENV['MAXMIND_ACCOUNT_ID']
SLACK_WEBHOOK_URL = ENV['SLACK_WEBHOOK_URL']
SAMPLE_SIZE = (ENV['SAMPLE_SIZE'] || '500_000').delete('_').to_i
STEP = (ENV['STEP'] || '0').to_i
PROGRESS = (ENV['PROGRESS'] || '0').to_i
RANDOM_SEED = Random.new_seed
DEFAULT_SAMPLE_SIZE = 500_000

class SimpleLogger
  def info(msg)
    puts "[#{Time.now.utc.iso8601}] #{msg}"
    $stdout.flush
  end

  def error(msg)
    warn "[#{Time.now.utc.iso8601}] ERROR: #{msg}"
    $stderr.flush
  end
end

def compare_and_report(baseline_path, new_mmdb_path, logger)
  logger.info('Opening MMDB files...')
  db_baseline = MaxMindDB.new(baseline_path)
  db_new = MaxMindDB.new(new_mmdb_path)

  sample_limit = SAMPLE_SIZE.positive? ? SAMPLE_SIZE : DEFAULT_SAMPLE_SIZE
  ips = if STEP.positive?
          ipv4_sample_with_step(STEP, sample_limit).to_a
        else
          ipv4_random_sample(sample_limit)
        end

  total = ips.size
  found_a = 0
  found_b = 0
  both = 0
  same_country = 0
  diff_country = 0

  logger.info("Starting comparison of #{total} IPs...")
  ips.each_with_index do |ip, i|
    if PROGRESS.positive? && ((i + 1) % PROGRESS).zero?
      logger.info("Processed #{i + 1}/#{total} IPs...")
    end

    res_a = db_baseline.lookup(ip)
    res_b = db_new.lookup(ip)

    found_a += 1 if res_a&.found?
    found_b += 1 if res_b&.found?

    next unless res_a&.found? && res_b&.found?

    both += 1
    code_a = res_a.country&.iso_code
    code_b = res_b.country&.iso_code
    if code_a == code_b
      same_country += 1
    else
      diff_country += 1
    end
  end

  # Report
  report_lines = []
  report_lines << '========== MMDB COMPARISON REPORT =========='
  report_lines << "  Baseline file (GCS):  gs://#{GCS_BUCKET}/#{GCS_OBJECT}"
  report_lines << '  New file (MaxMind):   MaxMind GeoLite2-Country'
  report_lines << "  IPs Checked:          #{total}"
  report_lines << "  Found (baseline):     #{found_a}"
  report_lines << "  Found (new):          #{found_b}"
  report_lines << "  Found in both:        #{both}"
  report_lines << "  Same country:         #{same_country}"
  report_lines << "  Different country:    #{diff_country}"

  compared = same_country + diff_country
  pct = 0.0
  if compared.positive?
    pct = (100.0 * diff_country / compared).round(2)
    report_lines << "  % Difference:         #{pct}%"
    
    # Suggestions based on % difference
    if pct < 5
      report_lines << '  Suggestion: Difference < 5%, keeping current baseline is recommended.'
    elsif pct > 5
      report_lines << '  Suggestion: Difference > 5%, consider updating baseline on Storage.'
    end
  else
    report_lines << '  % Difference:         N/A (No IPs found in both databases)'
  end
  report_lines << '==========================================='
  
  report_text = report_lines.join("\n")
  puts "\n#{report_text}\n"

  # Send to Slack if configured
  if SLACK_WEBHOOK_URL
    slack = SlackNotifierService.new(webhook_url: SLACK_WEBHOOK_URL, logger: logger)
    
    # Format mention and status
    mentions = "<@U04TNE9NBND> <@U03PJRCJM37> <@U08US47H0N7>"
    status_emoji = pct < 5 ? ":large_green_circle:" : ":red_circle:"
    limit_text = pct < 5 ? "(<5%)" : "(>5%)"
    
    slack_message = "#{mentions}\nSo sánh GeoLite2 trên #{total} IP: chênh lệch #{pct}% #{limit_text} #{status_emoji}"
    slack.send_message(slack_message)
  end
end

def ipv4_sample_with_step(step, limit)
  return enum_for(:ipv4_sample_with_step, step, limit) unless block_given?

  n = 0
  (0..0xffff_ffff).step(step) do |i|
    break if n >= limit

    o1 = (i >> 24) & 0xff
    o2 = (i >> 16) & 0xff
    o3 = (i >> 8) & 0xff
    o4 = i & 0xff
    yield "#{o1}.#{o2}.#{o3}.#{o4}"
    n += 1
  end
end

def ipv4_random_sample(size)
  require 'ipaddr'
  r = Random.new(RANDOM_SEED)
  samples = []
  while samples.size < size
    a = r.rand(1..254)
    b = r.rand(0..255)
    c = r.rand(0..255)
    d = r.rand(1..254)
    ip_str = "#{a}.#{b}.#{c}.#{d}"
    ip = IPAddr.new(ip_str)
    
    # Exclude non-public IP ranges
    next if ip.private? || ip.loopback? || ip.link_local? || (a >= 224) # Multicast/Reserved
    
    samples << ip_str
  end
  samples
end

def main
  logger = SimpleLogger.new
  temp_dir = Dir.mktmpdir('compare_mmdb')
  baseline_path = File.join(temp_dir, 'baseline.mmdb')
  tar_path = File.join(temp_dir, 'geolite2.tar.gz')
  extract_dir = File.join(temp_dir, 'maxmind_extract')
  new_mmdb_path = File.join(temp_dir, 'new.mmdb')

  begin
    unless GCS_BUCKET
      logger.error('GCS_BUCKET environment variable is not set.')
      exit 1
    end

    gcp_project_id = ENV.fetch('GCP_PROJECT_ID', nil)
    gcs = GcsBaselineDownloader.new(bucket: GCS_BUCKET, object: GCS_OBJECT, project_id: gcp_project_id, logger: logger)
    unless gcs.download_to(baseline_path)
      exit 1
    end

    maxmind = MaxMindDownloaderService.new(
      license_key: MAXMIND_LICENSE_KEY,
      account_id: MAXMIND_ACCOUNT_ID,
      logger: logger
    )
    result = maxmind.download_and_extract(tar_path, extract_dir, new_mmdb_path)
    unless result[:success]
      logger.error(result[:error])
      exit 1
    end

    compare_and_report(baseline_path, new_mmdb_path, logger)
    exit 0
  rescue StandardError => e
    logger.error("Error: #{e.message}")
    e.backtrace.first(5).each { |line| logger.error(line) }
    exit 1
  ensure
    logger.info('Deleting temporary files...')
    FileUtils.rm_rf(temp_dir)
  end
end

main if __FILE__ == $0
