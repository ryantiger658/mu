# Copyright:: Copyright (c) 2014 eGlobalTech, Inc., all rights reserved
#
# Licensed under the BSD-3 license (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License in the root of the project or at
#
#     http://egt-labs.com/mu/LICENSE.html
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'pp'
require 'base64'
require 'etc'

# Load our configuration settings directly, rather than depending on our
# invoking environment having been completely sane. Really we shouldn't be
# doing much with the environment at all...
# @param path [String]: The path to a .murc file to load.
# @return [void]
def parseRCFile(path)
  if File.readable?(path)
    File.readlines(path).each { |line|
      line.strip!
      name, value = line.split(/=/, 2)
      name.sub!(/^export /, "")
      if !value.nil? and !value.empty?
        value.gsub!(/(^"|"$)/, "")
        ENV[name] = value if !value.match(/\$/)
        puts "Setting MURC variable #{name}=#{value}"
      end
    }
  end
end

if ENV.include?('MU_INSTALLDIR')
  parseRCFile ENV['MU_INSTALLDIR']+"/etc/mu.rc"
else
  parseRCFile "/opt/mu/etc/mu.rc"
end

home = Etc.getpwuid(Process.uid).dir
parseRCFile "#{home}/.murc"

if !ENV.include?('MU_INSTALLDIR')
  puts "Environment isn't set and I can't find a useful .murc, aborting."
  exit 1
end
if !ENV.include?('MU_LIBDIR')
  ENV['MU_LIBDIR'] = ENV['MU_INSTALLDIR']+"/lib"
end

$MUDIR = ENV['MU_LIBDIR']

$LOAD_PATH << "#{$MUDIR}/modules"

require File.realpath(File.expand_path(File.dirname(__FILE__)+"/mu-load-config.rb"))
require 'mu'

MU::Groomer::Chef.loadChefLib # pre-cache this so we don't take a hit on a user-interactive need
#MU.setLogging($opts[:verbose], $opts[:web])

Signal.trap("URG") do
  puts "------------------------------"
  puts "Open flock() locks:"
  pp MU::MommaCat.locks
  puts "------------------------------"
end

begin
  MU::MommaCat.syncMonitoringConfig(false)
rescue Exception => e
  MU.log e.inspect, MU::ERR, details: e.backtrace
  # ...but don't die!
end

parent_thread_id = Thread.current.object_id
Thread.new {
  MU.dupGlobals(parent_thread_id)
  begin
    MU::MommaCat.cleanTerminatedInstances
    MU::Master.cleanExpiredScratchpads
    sleep 60
  rescue Exception => e
    MU.log "Error in cleanTerminatedInstances thread: #{e.inspect}", MU::ERR, details: e.backtrace
    retry
  end while true
}

required_vars = ["mu_id", "mu_deploy_secret", "mu_resource_name", "mu_resource_type", "mu_instance_id"]

# Use a template to generate a pleasant-looking HTML page for simple messages
# and errors.
def genHTMLMessage(title: "", headline: "", msg: "", template: $MU_CFG['html_template'], extra_vars: {})
  logo_url = "http://#{$MU_CFG['public_address']}/cloudamatic.png"
  page = "<img src='#{logo_url}'><h1>#{title}</h1>#{msg}"
  vars = {
    "title" => title,
    "msg" => msg,
    "headline" => headline,
    "logo" => logo_url
  }.merge(extra_vars)
  if !template.nil? and File.exist?(template) and File.readable?(template)
    page = Erubis::Eruby.new(File.read(template)).result(vars)
  elsif $MU_CFG.has_key?('html_template') and
     File.exist?($MU_CFG['html_template']) and
     File.readable?($MU_CFG['html_template'])
    page = Erubis::Eruby.new(File.read($MU_CFG['html_template'])).result(vars)
  elsif File.exist?("#{$MU_CFG['libdir']}/modules/html.erb") and
     File.readable?("#{$MU_CFG['libdir']}/modules/html.erb")
    page = Erubis::Eruby.new(File.read("#{$MU_CFG['libdir']}/modules/html.erb")).result(vars)
  end
  page
end

# Return an error message to web clients.
def throw500(msg = "", details = nil)
  MU.log "Returning 500 to client: #{msg}", MU::ERR, details: details
  page = genHTMLMessage(title: "500 Error", headline: msg, msg: details)
  [
      500,
      {
          'Content-Type' => 'text/html',
          'Content-Length' => page.length.to_s
      },
      [page]
  ]
end

def throw404(msg = "", details = nil)
  MU.log "Returning 404 to client: #{msg}", MU::ERR, details: details
  page = genHTMLMessage(title: "404 Not Found", headline: msg, msg: details)
  [
      404,
      {
          'Content-Type' => 'text/html',
          'Content-Length' => page.length.to_s
      },
      [page]
  ]
end

def returnRawJSON(data)
  MU.log "Returning 200 to client", MU::NOTICE, details: data
  [
      200,
      {
          'Content-Type' => 'application/json',
          'Content-Length' => data.length.to_s
      },
      [data]
  ]
end

@litters = Hash.new
@litter_semaphore = Mutex.new


# Load a {MU::MommaCat} instance for the requested deployment.
# @param req [Hash]: The web request describing the requested deployment. Must include a *mu_id* and *mu_deploy_secret*. 
# return [MU::MommaCat]
def getKittenPile(req)
  @litter_semaphore.synchronize {
    mu_id = req["mu_id"]
    if !@litters.has_key?(mu_id)
      begin
        kittenpile = MU::MommaCat.new(
            mu_id,
            deploy_secret: Base64.urlsafe_decode64(req["mu_deploy_secret"]),
            set_context_to_me: true,
            mu_user: req['mu_user']
        )
      rescue MU::MommaCat::DeployInitializeError => e
        MU.log e.inspect, MU::ERR, details: req
        return nil
      end
      @litters[mu_id] = Hash.new
      @litters[mu_id]['kittenpile'] = kittenpile
      @litters[mu_id]['kittencount'] = 1
      @litters[mu_id]['threads'] = [Thread.current.object_id]
    else
      @litters[mu_id]['kittencount'] += 1
      @litters[mu_id]['threads'] << Thread.current.object_id
      MU.dupGlobals(@litters[mu_id]['threads'].first)
    end
    # Make sure enough per-thread global MU class variables are set for us
    # to operate in this thread context

    MU.setVar("mu_id", mu_id)
    MU.setVar("mommacat", @litters[mu_id]['kittenpile'])
    MU.log "Adding kitten in #{mu_id}: #{@litters[mu_id]['kittencount']}", MU::DEBUG, details: @litters
    return @litters[mu_id]['kittenpile']
  }
end

# Release a {MU::MommaCat} object.
# @param mu_id [String]: The MU identifier of the loaded deploy to replace.
def releaseKitten(mu_id)
  @litter_semaphore.synchronize {
    if @litters.has_key?(mu_id)
      @litters[mu_id]['kittencount'] -= 1
      @litters[mu_id]['threads'].delete(Thread.current.object_id)
      MU.log "Releasing kitten in #{mu_id}: #{@litters[mu_id]['kittencount']}", MU::DEBUG, details: @litters
      if @litters[mu_id]['kittencount'] < 1
        @litters.delete(mu_id)
      end
      MU.purgeGlobals
    end
  }
end

app = proc do |env|
  ok = false
  returnval = [
      200,
      {
          'Content-Type' => 'text/html',
          'Content-Length' => '2'
      },
      ['hi']
  ]
  begin
    if !env.nil? and !env['REQUEST_PATH'].nil? and env['REQUEST_PATH'].match(/^\/scratchpad/)
      itemname = env['REQUEST_PATH'].sub(/^\/scratchpad\//, "")
      begin
        secret = MU::Master.fetchScratchPadSecret(itemname)
        MU.log "Retrieved scratchpad secret #{itemname} for #{env['REMOTE_ADDR']}"
        page = nil
        if $MU_CFG.has_key?('scratchpad') and
           $MU_CFG['scratchpad'].has_key?("template_path") and
           File.exist?($MU_CFG['scratchpad']['template_path']) and
           File.readable?($MU_CFG['scratchpad']['template_path'])
          page = genHTMLMessage(
            title: "Your Scratchpad Secret",
            headline:"<strong>YOU MAY ONLY RETRIVE THIS SECRET ONCE!</strong> Be sure to copy it somewhere safe before reloading, browsing away, or closing your browser window.",
            msg: secret,
            template: $MU_CFG['scratchpad']['template_path'],
            extra_vars: { "secret" => secret }
          )
        else
          page = genHTMLMessage(
            title: "Your Scratchpad Secret",
            headline:"<strong>YOU MAY ONLY RETRIVE THIS SECRET ONCE!</strong> Be sure to copy it somewhere safe before reloading, browsing away, or closing your browser window.",
            msg: secret
          )
        end

        returnval = [
          200,
          {
            'Content-Type' => 'text/html',
            'Content-Length' => page.length.to_s
          },
          [page]
        ]
      rescue MU::Groomer::Chef::MuNoSuchSecret
        page = genHTMLMessage(title: "No such secret", msg: "The secret '#{itemname}' does not exist or has already been retrieved")
        returnval = [
          200,
          {
            'Content-Type' => 'text/html',
            'Content-Length' => page.length.to_s
          },
          [page]
        ]
      end
    elsif !env.nil? and !env['REQUEST_PATH'].nil? and env['REQUEST_PATH'].match(/^\/rest\//)
      action, filter, path = env['REQUEST_PATH'].sub(/^\/rest\/?/, "").split(/\//, 3)
      # Don't give away the store. This can't be public until we can
      # authenticate and access-control properly.
      if env['REMOTE_ADDR'] != "127.0.0.1" and action != "bucketname"
        returnval = throw500 "Service not available"
        next
      end

      if action == "deploy"
        returnval = throw404 env['REQUEST_PATH'] if !filter
        MU.log "Loading deploy data for #{filter} #{path}"
        kittenpile = MU::MommaCat.getLitter(filter)
        returnval = returnRawJSON JSON.generate(kittenpile.deployment)
      elsif action == "config"
        returnval = throw404 env['REQUEST_PATH'] if !filter
        MU.log "Loading config #{filter} #{path}"
        kittenpile = MU::MommaCat.getLitter(filter)
        returnval = returnRawJSON JSON.generate(kittenpile.original_config)
      elsif action == "list"
        MU.log "Listing deployments"
        returnval = returnRawJSON JSON.generate(MU::MommaCat.listDeploys)
      elsif action == "bucketname"
        returnval = [
          200,
          {
            'Content-Type' => 'text/plain',
            'Content-Length' => MU.adminBucketName.length.to_s
          },
          [MU.adminBucketName]
        ]
      else
        returnval = throw404 env['REQUEST_PATH']
      end

    elsif !env["rack.input"].nil?
      req = Rack::Utils.parse_nested_query(env["rack.input"].read)
      ok = true

      if req["mu_user"].nil?
        req["mu_user"] = "mu"
      end

      MU.log "Processing request from #{env["REMOTE_ADDR"]} (MU-ID #{req["mu_id"]}, #{req["mu_resource_type"]}: #{req["mu_resource_name"]}, instance: #{req["mu_instance_id"]}, mu_ssl_sign: #{req["mu_ssl_sign"]}, mu_user #{req['mu_user']}, path #{env['REQUEST_PATH']})"
      kittenpile = getKittenPile(req)
      if kittenpile.nil? or kittenpile.original_config.nil? or kittenpile.original_config[req["mu_resource_type"]+"s"].nil?
        returnval = throw500 "Couldn't find config data for #{req["mu_resource_type"]} in deploy_id #{req["mu_id"]}"
        ok = false
        next
      end
      server_cfg = nil
      kittenpile.original_config[req["mu_resource_type"]+"s"].each { |svr|
        if svr["name"] == req["mu_resource_name"]
          server_cfg = svr.dup
          break
        end
      }
      if server_cfg.nil?
        returnval = throw500 "Couldn't find config data for #{req["mu_resource_type"]} name: #{req["mu_resource_name"]} deploy_id: #{req["mu_id"]}"
        ok = false
        next
      end

      MU.log "Dug up server config for #{req["mu_resource_type"]} name: #{req["mu_resource_name"]} deploy_id: #{req["mu_id"]}", MU::DEBUG, details: server_cfg

# XXX We can't assume AWS anymore. What does this look like otherwise?
# If this is an already-groomed instance, try to get a real object for it
      instance = MU::MommaCat.findStray("AWS", "server", cloud_id: req["mu_instance_id"], region: server_cfg["region"], deploy_id: req["mu_id"], name: req["mu_resource_name"], dummy_ok: false).first
      mu_name = nil
      if instance.nil?
        # Now we're just checking for existence in the cloud provider, really
        MU.log "No existing groomed server found, verifying that a server with this cloud id exists"
        instance = MU::Cloud::Server.find(cloud_id: req["mu_instance_id"], region: server_cfg["region"])
      else
        mu_name = instance.mu_name
        MU.log "Found an existing node named #{mu_name}"
      end
      if !req["mu_ssl_sign"].nil?
        kittenpile.signSSLCert(req["mu_ssl_sign"])
      elsif !req["add_volume"].nil?
puts instance.cloud_id
pp req
        if instance.respond_to?(:addVolume)
# XXX make sure we handle mangled input safely
          params = JSON.parse(Base64.decode64(req["add_volume"]))
          instance.addVolume(params["dev"], params["size"])
        else
          returnval = throw500 "I don't know how to add a volume for #{instance}"
          ok = false
        end
      elsif !instance.nil?
        if !req["mu_bootstrap"].nil?
          kittenpile.groomNode(req["mu_instance_id"], req["mu_resource_name"], req["mu_resource_type"], mu_name: mu_name, sync_wait: true)
        else
          returnval = throw500 "Didn't get 'mu_bootstrap' parameter from instance id '#{req["mu_instance_id"]}'"
          ok = false
        end
      else
        returnval = throw500 "No such instance id '#{req["mu_instance_id"]}' nor was this an SSL signing request"
        ok = false
      end
    end
  rescue Exception => e
    returnval = throw500 "Invalid request: #{e.inspect} (#{req})", e.backtrace
    ok = false
  ensure
    if !req.nil?
      releaseKitten(req['mu_id'])
      MU.purgeGlobals
    end
  end
  returnval
end

run app
