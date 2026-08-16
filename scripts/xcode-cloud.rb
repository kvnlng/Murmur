#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Read Xcode Cloud build results from the App Store Connect API.
#
# Why this exists: when a Cloud build fails, the GitHub check-run summary
# gives you the assertion message and nothing else — no console output, no
# xcresult, no crash logs. Those live behind the API, and getting at them
# needs an ES256-signed JWT. This wraps that.
#
# Setup (one time) is documented in XCODE_CLOUD.md. In short, this expects:
#
#   ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8   chmod 600
#   ~/.appstoreconnect/issuer_id                          chmod 600
#
# Nothing secret is read from or written to this repo. The key ID is taken
# from the .p8 filename, which is how Apple names the download.
#
# Deliberately dependency-free: system Ruby (2.6 on macOS) ships an OpenSSL
# that can sign ES256, so this runs on a clean checkout with no `gem install`
# and no Homebrew. That also means no endless method definitions, no
# `filter_map`, and no pattern matching — keep it 2.6-compatible.
#
# Usage:
#   scripts/xcode-cloud.rb builds [count]        recent build runs
#   scripts/xcode-cloud.rb run <id|latest>       one run, with its actions
#   scripts/xcode-cloud.rb issues <action-id>    warnings/errors for an action
#   scripts/xcode-cloud.rb artifacts <action-id> downloadable artifacts
#   scripts/xcode-cloud.rb download <artifact-id> [dest-dir]
#   scripts/xcode-cloud.rb get <api-path>        raw JSON passthrough
#
# `latest` resolves to the most recent run, so the common case after a
# failure email is:
#
#   scripts/xcode-cloud.rb run latest

require "openssl"
require "base64"
require "json"
require "net/http"
require "uri"
require "fileutils"

CONFIG_DIR = File.expand_path("~/.appstoreconnect")
API_HOST = "api.appstoreconnect.apple.com"

module ASC
  module_function

  def key_path
    @key_path ||= begin
      found = Dir[File.join(CONFIG_DIR, "private_keys", "AuthKey_*.p8")].sort
      if found.empty?
        abort "No AuthKey_*.p8 in #{CONFIG_DIR}/private_keys — see XCODE_CLOUD.md"
      end
      # More than one key is legal but ambiguous; be loud rather than guess.
      if found.length > 1
        warn "warning: #{found.length} keys present, using #{File.basename(found.first)}"
      end
      found.first
    end
  end

  def key_id
    File.basename(key_path)[/AuthKey_(.+)\.p8/, 1]
  end

  def issuer
    @issuer ||= begin
      path = File.join(CONFIG_DIR, "issuer_id")
      abort "Missing #{path} — see XCODE_CLOUD.md" unless File.exist?(path)
      File.read(path).strip
    end
  end

  def b64(str)
    Base64.urlsafe_encode64(str).delete("=")
  end

  # ES256 JWT. Apple caps the lifetime at 20 minutes; 15 leaves room for slow
  # calls without tripping the limit. The signature has to be raw r||s, not the
  # DER sequence OpenSSL hands back, hence the unpack-and-pad below.
  def token
    key = OpenSSL::PKey::EC.new(File.read(key_path))
    header = b64({ alg: "ES256", kid: key_id, typ: "JWT" }.to_json)
    now = Time.now.to_i
    payload = b64({ iss: issuer, iat: now, exp: now + 900,
                    aud: "appstoreconnect-v1" }.to_json)
    der = key.sign(OpenSSL::Digest::SHA256.new, "#{header}.#{payload}")
    r, s = OpenSSL::ASN1.decode(der).value.map do |v|
      v.value.to_s(2).rjust(32, "\x00")
    end
    "#{header}.#{payload}.#{b64(r + s)}"
  end

  def get(path)
    uri = URI(path.start_with?("http") ? path : "https://#{API_HOST}#{path}")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{token}"
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.request(request)
    end
    unless response.code == "200"
      abort "HTTP #{response.code} for #{uri.path}\n#{response.body}"
    end
    JSON.parse(response.body)
  end

  # The only product is Murmur, but resolve it rather than hardcoding the UUID
  # so this keeps working if the product is ever recreated.
  def product_id
    @product_id ||= begin
      products = get("/v1/ciProducts")["data"]
      abort "No Xcode Cloud products visible to this key" if products.empty?
      products.first["id"]
    end
  end

  def build_runs(limit)
    get("/v1/ciProducts/#{product_id}/buildRuns?limit=#{limit}&sort=-number")["data"]
  end

  def resolve_run(id)
    return id unless id == "latest"

    runs = build_runs(1)
    abort "No build runs found" if runs.empty?
    runs.first["id"]
  end
end

def format_run(attrs, id = nil)
  status = attrs["completionStatus"] || attrs["executionProgress"]
  commit = attrs["sourceCommit"] || {}
  sha = (commit["commitSha"] || "")[0, 8]
  subject = (commit["message"] || "").split("\n").first.to_s
  line = format("#%-4s %-10s %-8s %s  %s", attrs["number"], status, sha,
                (attrs["startedDate"] || "")[0, 16], subject[0, 54])
  id ? "#{line}\n     #{id}" : line
end

def cmd_builds(args)
  limit = (args.first || "15").to_i
  ASC.build_runs(limit).each { |run| puts format_run(run["attributes"]) }
end

def cmd_run(args)
  abort "usage: run <id|latest>" if args.empty?
  id = ASC.resolve_run(args.first)
  run = ASC.get("/v1/ciBuildRuns/#{id}")["data"]
  puts format_run(run["attributes"], id)
  puts

  ASC.get("/v1/ciBuildRuns/#{id}/actions")["data"].each do |action|
    a = action["attributes"]
    puts format("  %-12s %-10s %s", a["actionType"], a["completionStatus"], a["name"])
    puts "    #{action['id']}"
  end
  puts
  puts "  artifacts: scripts/xcode-cloud.rb artifacts <action-id>"
end

def cmd_issues(args)
  abort "usage: issues <action-id>" if args.empty?
  issues = ASC.get("/v1/ciBuildActions/#{args.first}/issues")["data"]
  # Errors and test failures matter far more than the SwiftLint warning
  # firehose, so lead with them.
  ranked = issues.sort_by { |i| i["attributes"]["issueType"] == "WARNING" ? 1 : 0 }
  ranked.each do |issue|
    a = issue["attributes"]
    puts "[#{a['issueType']}] #{a['message']}"
  end
  puts "(#{issues.length} issues)"
end

def cmd_artifacts(args)
  abort "usage: artifacts <action-id>" if args.empty?
  ASC.get("/v1/ciBuildActions/#{args.first}/artifacts")["data"].each do |art|
    a = art["attributes"]
    size_mb = (a["fileSize"].to_f / 1_048_576).round(1)
    puts format("%-14s %8s MB  %s", a["fileType"], size_mb, a["fileName"])
    puts "  #{art['id']}"
  end
end

def cmd_download(args)
  abort "usage: download <artifact-id> [dest-dir]" if args.empty?
  dest_dir = args[1] || Dir.pwd
  artifact = ASC.get("/v1/ciArtifacts/#{args.first}")["data"]["attributes"]
  url = artifact["downloadUrl"]
  abort "No download URL — the artifact may have expired" if url.nil? || url.empty?

  FileUtils.mkdir_p(dest_dir)
  dest = File.join(dest_dir, File.basename(artifact["fileName"]))
  # Artifacts are served from iCloud with a signed, short-lived URL and at
  # least one redirect, so let curl handle the hop and the progress meter.
  system("curl", "-fsSL", "--progress-bar", "-o", dest, url) or abort "download failed"
  puts dest
end

def cmd_get(args)
  abort "usage: get <api-path>" if args.empty?
  puts JSON.pretty_generate(ASC.get(args.first))
end

COMMANDS = {
  "builds" => method(:cmd_builds),
  "run" => method(:cmd_run),
  "issues" => method(:cmd_issues),
  "artifacts" => method(:cmd_artifacts),
  "download" => method(:cmd_download),
  "get" => method(:cmd_get)
}.freeze

if __FILE__ == $PROGRAM_NAME
  command = ARGV.shift
  handler = COMMANDS[command]
  unless handler
    warn "usage: #{File.basename($PROGRAM_NAME)} <#{COMMANDS.keys.join('|')}> [args]"
    exit 1
  end
  handler.call(ARGV)
end
