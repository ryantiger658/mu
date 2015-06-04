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

gem "chef"
autoload :Chef, 'chef'
gem "knife-windows"
gem "chef-vault"
autoload :Chef, 'chef-vault'
autoload :ChefVault, 'chef-vault'
require 'net/ssh'
require 'net/ssh/multi'
require 'net/ssh/proxy/command'
autoload :OpenStruct, "ostruct"
autoload :Timeout, "timeout"
autoload :ERB, "erb"
autoload :Base64, "base64"
require 'open-uri'

module MU


	# A server as configured in {MU::Config::BasketofKittens::servers}
	class Server
		# An exception denoting an expected, temporary connection failure to a
		# bootstrapping instance, e.g. for Windows instances that must reboot in
		# mid-installation.
		class BootstrapTempFail < MuNonFatal
		end

		# An exception denoting a Chef run that has failed, but could potentially
		# be successful on a subsequent run.
		class ChefRunFail < MuError
		end

		# The {MU::Config::BasketofKittens} name for a single resource of this class.
		def self.cfg_name; "server".freeze end
		# The {MU::Config::BasketofKittens} name for a collection of resources of this class.
		def self.cfg_plural; "servers".freeze end
		# Whether {MU::Deploy} should hold creation of other resources which depend on this resource until the latter has been created.
		def self.deps_wait_on_my_creation; false.freeze end
		# Whether {MU::Deploy} should hold creation of this resource until resources on which it depends have been fully created and deployed.
		def self.waits_on_parent_completion; false.freeze end

		# @return [Mutex]
		def self.userdata_mutex
			@userdata_mutex ||= Mutex.new
		end

		# A list of block device names to use if we get a storage block that
		# doesn't declare one explicitly.
		# This probably fails on some AMIs. It's crude.
		@disk_devices = [
			"/dev/sdf",
			"/dev/sdg",
			"/dev/sdh",
			"/dev/sdi",
			"/dev/sdj",
			"/dev/sdk",
			"/dev/sdl",
			"/dev/sdm",
			"/dev/sdn"
		]
		# List of standard disk device names to present to instances.
		# @return [Array<String>]
		def self.disk_devices
			@disk_devices
		end

		# See that we get our ephemeral storage devices with AMIs that don't do it
		# for us
		@ephemeral_mappings = [
			{
				:device_name => "/dev/sdr",
				:virtual_name => "ephemeral0"
			},
			{
				:device_name => "/dev/sds",
				:virtual_name => "ephemeral1"
			},
			{
				:device_name => "/dev/sdt",
				:virtual_name => "ephemeral2"
			},
			{
				:device_name => "/dev/sdu",
				:virtual_name => "ephemeral3"
			}
		]
		# Ephemeral storage device mappings. Useful for AMIs that don't do this
		# for us.
		# @return [Hash]
		def self.ephemeral_mappings
			@ephemeral_mappings
		end

		# @param deployer [MU::Deploy]: A {MU::Deploy} object, typically associated with an in-progress deployment.
		# @param server [Hash]: The full {MU::Config} resource declaration as defined in {MU::Config::BasketofKittens::servers}
		def initialize(deployer, server)
			@deploy = deployer
			@server = server
		  node = MU::MommaCat.getResourceName(server['name'])
			@server['mu_name'] = node
			MU.setVar("curRegion", @server['region']) if !@server['region'].nil?

			if File.exists?(Etc.getpwuid(Process.uid).dir+"/.chef/knife.rb")
				Chef::Config.from_file(Etc.getpwuid(Process.uid).dir+"/.chef/knife.rb")
			end
			Chef::Config[:environment] = @deploy.environment

			if %w{win2k12r2 win2k12 windows}.include?(@server['platform']) or !@server['active_directory'].nil?
				@server['mu_windows_name'] = MU::MommaCat.getResourceName(server['name'], max_length: 15, need_unique_string: true)
				if !@server['never_generate_admin_password'] and !@server['windows_admin_password']
					@server['winpass'] = MU::Server.generateWindowsAdminPassword
					MU.log "I generated a Windows admin password for #{node}. It is: #{@server['winpass']}"
				end
			end
			keypairname, ssh_private_key, ssh_public_key = @deploy.createEc2SSHKey

			@server['instance_secret'] = Password.random(50)
			@userdata = MU::Server.fetchUserdata(
				platform: @server["platform"],
				template_variables: {
					"deployKey" => Base64.urlsafe_encode64(MU.mommacat.public_key),
					"deploySSHKey" => ssh_public_key,
					"muID" => MU.mu_id,
					"muUser" => MU.chef_user,
					"publicIP" => MU.mu_public_ip,
					"skipApplyUpdates" => @server['skipinitialupdates'],
					"windowsAdminName" => @server['windows_admin_username'],
					"resourceName" => @server["name"],
					"resourceType" => "server"
				},
				custom_append: @server['userdata_script']
			)

			@disk_devices = MU::Server.disk_devices
			@ephemeral_mappings = MU::Server.ephemeral_mappings
		end

		# Fetch our baseline userdata argument (read: "script that runs on first
		# boot") for a given platform.
		# *XXX* both the eval() and the blind File.read() based on the platform
		# variable are dangerous without cleaning. Clean them.
		# @param platform [String]: The target OS.
		# @param template_variables [Hash]: A list of variable substitutions to pass as globals to the ERB parser when loading the userdata script.
		# @param custom_append [String]: Arbitrary extra code to append to our default userdata behavior.
		# @return [String]
		def self.fetchUserdata(
														platform: platform = "linux",
														template_variables: template_variables = Hash.new,
														custom_append: custom_append = nil
													)
			userdata_mutex.synchronize {
				if template_variables.nil? or !template_variables.is_a?(Hash)
					raise MuError, "My second argument should be a hash of variables to pass into ERB templates"
				end
				$mu = OpenStruct.new(template_variables)
				userdata_dir = File.expand_path(File.dirname(__FILE__)+"/../userdata")
				platform = "linux" if %w{centos centos6 centos7 ubuntu ubuntu14}.include? platform
				platform = "windows" if %w{win2k12r2 win2k12}.include? platform
				erbfile = "#{userdata_dir}/#{platform}.erb"
				if !File.exist?(erbfile)
					MU.log "No such userdata template '#{erbfile}'", MU::WARN
					return ""
				end
				userdata = File.read(erbfile)
				begin
					erb = ERB.new(userdata)
					script = erb.result
				rescue NameError => e
					raise MuError, "Error parsing userdata script #{erbfile} as an ERB template: #{e.inspect}"
				end
				MU.log "Parsed #{erbfile} as ERB", MU::DEBUG, details: script
				if !custom_append.nil?
					if custom_append['path'].nil?
						raise MuError, "Got a custom userdata script argument, but no ['path'] component"
					end
					erbfile = File.read(custom_append['path'])
					MU.log "Loaded userdata script from #{custom_append['path']}"
					if custom_append['use_erb']
						begin
							erb = ERB.new(erbfile, 1)
							script = script+"\n"+erb.result
						rescue NameError => e
							raise MuError, "Error parsing userdata script #{erbfile} as an ERB template: #{e.inspect}"
						end
						MU.log "Parsed #{custom_append['path']} as ERB", MU::DEBUG, details: script
					else
						script = script+"\n"+erb.result
						MU.log "Parsed #{custom_append['path']} as flat file", MU::DEBUG, details: script
					end
				end
				return script
			}
		end

		# Find volumes attached to a given instance id and tag them. If no arguments
		# besides the instance id are provided, it will add our special MU-ID
		# tag. Can also be used to do things like set the resource's name, if you
		# leverage the other arguments.
		# @param instance_id [String]: The cloud provider's identifier for the parent instance of this volume.
		# @param device [String]: The OS-level device name of the volume.
		# @param tag_name [String]: The name of the tag to attach.
		# @param tag_value [String]: The value of the tag to attach.
		# @param region [String]: The cloud provider region
		# @return [void]
		def self.tagVolumes(instance_id, device=nil, tag_name="MU-ID", tag_value=MU.mu_id, region: MU.curRegion)
			begin
			  MU.ec2(region).describe_volumes(filters: [name: "attachment.instance-id", values: [instance_id]]).each { |vol|
			    vol.volumes.each { |volume|
						volume.attachments.each { |attachment|
							vol_parent = attachment.instance_id
							vol_id = attachment.volume_id
							vol_dev = attachment.device
							if vol_parent == instance_id and (vol_dev == device or device.nil?) 
								MU::MommaCat.createTag(vol_id, tag_name, tag_value, region: region)
								break
							end
						}
					}
				}
			rescue Aws::EC2::Errors::RequestLimitExceeded
				sleep 10
				retry
			end
		end
		

		# Called automatically by {MU::Deploy#createResources}
		def create
			begin
				done = false
				instance = createEc2Instance

				@server["instance_id"] = instance.instance_id
				MU.mommacat.saveSecret(@server["instance_id"], @server['instance_secret'], "instance_secret")
				@server.delete("instance_secret")
				if !@server['winpass'].nil?
					MU.mommacat.saveSecret(@server["instance_id"], @server['winpass'], "windows_password")
					@server.delete("winpass")
				end
				if !@deploy.mommacat_boot
					sleep 5
					MU::MommaCat.lock(instance.instance_id+"-create")
					if !groomEc2(instance)
						MU.log "#{@server['name']} is already being groomed, skipping", MU::NOTICE
					else
						MU.log "Node creation complete for #{@server['name']}"
					end
					MU::MommaCat.unlock(instance.instance_id+"-create")
				else
					MU::MommaCat.createStandardTags(instance.instance_id, region: @server['region'])
				  MU::MommaCat.createTag(instance.instance_id,"Name",MU::MommaCat.getResourceName(@server['name']), region: @server['region'])
				end
				done = true
			rescue Exception => e
				if !instance.nil? and !done
					MU.log "Aborted before I could finish setting up #{@server['name']}, cleaning it up. Stack trace will print once cleanup is complete.", MU::WARN if !@deploy.nocleanup
					MU::MommaCat.unlockAll
					if !@deploy.nocleanup
						parent_thread_id = Thread.current.object_id
						Thread.new {
							MU.dupGlobals(parent_thread_id)
							MU::Server.terminateInstance(id: instance.instance_id)
						}
					end
				end
				raise e
			end

			return @server
		end

		# Remove the automatically generated IAM Profile for a given class of
		# server.
		# @param name [String]: The name field of the {MU::Server} or {MU::ServerPool} resource's IAM profile to remove.
		# @return [void]
		def self.removeIAMProfile(name)
			rolename = MU::MommaCat.getResourceName(name)
			MU.log "Removing IAM role and policies for '#{name}' nodes"
			begin
				MU.iam.remove_role_from_instance_profile(
					instance_profile_name: rolename,
					role_name: rolename
				)
			rescue Aws::IAM::Errors::NoSuchEntity => e
				MU.log "Cleaning up IAM role #{rolename}: #{e.inspect}", MU::DEBUG
			end
			begin
				MU.iam.delete_instance_profile(instance_profile_name: rolename)
			rescue Aws::IAM::Errors::NoSuchEntity => e
				MU.log "Cleaning up IAM role #{rolename}: #{e.inspect}", MU::DEBUG
			end
			begin
				policies = MU.iam.list_role_policies(role_name: rolename).policy_names
				policies.each { |policy|
					MU.iam.delete_role_policy(role_name: rolename, policy_name: policy)
				}
			rescue Aws::IAM::Errors::NoSuchEntity => e
				MU.log "Cleaning up IAM role #{rolename}: #{e.inspect}", MU::DEBUG
			end
			begin
				MU.iam.delete_role(role_name: rolename)
			rescue Aws::IAM::Errors::NoSuchEntity => e
				MU.log "Cleaning up IAM role #{rolename}: #{e.inspect}", MU::DEBUG
			end
		end

		# Create an Amazon IAM instance profile. One of these should get created
		# for each class of instance (each {MU::Server} or {MU::ServerPool}),
		# and will include both baseline Mu policies and whatever other policies
		# are requested.
		# @param name [String]: The name field of the {MU::Server} or {MU::ServerPool} resource's IAM profile to create.
		# @return [String]: The name of the instance profile.
		def self.createIAMProfile(name, base_profile: nil, extra_policies: nil)
			rolename = MU::MommaCat.getResourceName(name, max_length: 64)
			MU.log "Creating IAM role and policies for '#{name}' nodes"
			policies = Hash.new
			policies['Mu_Bootstrap_Secret'] ='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject"],"Resource":"arn:aws:s3:::'+MU.adminBucketName+'/'+"#{MU.mu_id}-secret"+'"}]}'
			policies['Mu_Volume_Management'] ='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["ec2:CreateTags","ec2:CreateVolume","ec2:AttachVolume","ec2:DescribeInstanceAttribute","ec2:DescribeVolumeAttribute","ec2:DescribeVolumeStatus","ec2:DescribeVolumes"],"Resource":"*"}]}'

			if base_profile
				MU.log "Incorporating policies from existing IAM profile '#{base_profile}'"
				resp = MU.iam.get_instance_profile(instance_profile_name: base_profile)
				resp.instance_profile.roles.each { |baserole|
					role_policies = MU.iam.list_role_policies(role_name: baserole.role_name).policy_names
					role_policies.each { |name|
						resp = MU.iam.get_role_policy(
							role_name: baserole.role_name,
							policy_name: name
						)
						policies[name] = URI.unescape(resp.policy_document)
					}
				}
			end
			if extra_policies
				MU.log "Incorporating other specified policies", details: extra_policies
				extra_policies.each { |policy_set|
					policy_set.each_pair { |name, policy|
						if policies.has_key?(name)
							MU.log "Attempt to add duplicate node policy '#{name}' to '#{rolename}'", MU::WARN, details: policy
							next
						end
						policies[name] = JSON.generate(policy)
					}
				}
			end
			resp = MU.iam.create_role(
				role_name: rolename,
				assume_role_policy_document: '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":["ec2.amazonaws.com"]},"Action":["sts:AssumeRole"]}]}'
			)
			begin
				name=doc=nil
				policies.each_pair { |name, doc|
					MU.log "Merging policy #{name} into #{rolename}", MU::NOTICE, details: doc
					MU.iam.put_role_policy(
						role_name: rolename,
						policy_name: name,
						policy_document: doc
					)
				}
			rescue Aws::IAM::Errors::MalformedPolicyDocument => e
				MU.log "Malformed policy when creating IAM Role #{rolename}: #{e.inspect}", MU::ERR
				raise MuError, "Malformed policy when creating IAM Role #{rolename}: #{e.inspect}"
			end
			MU.iam.create_instance_profile(
				instance_profile_name: rolename
			)
			MU.iam.add_role_to_instance_profile(
				instance_profile_name: rolename,
				role_name: rolename
			)

			return rolename
		end
		
		# Create an Amazon EC2 instance.
		def createEc2Instance
		  name = @server["name"]
		  node = @server['mu_name']
			begin
				@server['iam_role'] = MU::Server.createIAMProfile("Server-"+name, base_profile: @server['iam_role'], extra_policies: @server['iam_policies'])
			rescue Aws::EC2::Errors::RequestLimitExceeded => e
				sleep 10
				retry
			end
			@server['iam_role'] = @server['iam_role']

			begin
				@deploy.createEc2SSHKey
			rescue Aws::EC2::Errors::RequestLimitExceeded => e
				sleep 10
				retry
			end

		  instance_descriptor = {
		    :image_id => @server["ami_id"],
		    :key_name => @deploy.keypairname,
		    :instance_type => @server["size"],
		    :disable_api_termination => true,
		    :min_count => 1,
		    :max_count => 1,
				:network_interfaces => [
					{
						:associate_public_ip_address => name["associate_public_ip"]
					}
				]
		  }
			
			if !@server['private_ip'].nil?
				instance_descriptor[:private_ip_address] = @server['private_ip']
			end

			vpc_id=subnet_id=nat_host_name=nat_ssh_user = nil
			subnet_retries = 0
			if !@server["vpc"].nil?
				begin
					vpc_id, subnet_ids, nat_host_name, nat_ssh_user = MU::VPC.parseVPC(@server['vpc'])
				rescue Aws::EC2::Errors::ServiceError => e
					MU.log e.message, MU::ERR, details: @server
					if subnet_retries < 5
					  subnet_retries = subnet_retries + 1
					  sleep 15
					  retry
					end
					raise MuError, e.inspect
				end
				subnet_id = subnet_ids.first
				if subnet_id.nil? or subnet_id.empty?
					MU.log "Got null Subnet id out of #{@server['vpc']}", MU::ERR
					raise MuError, "deploy failure"
				end

				MU.log "Deploying #{node} into VPC #{vpc_id} Subnet #{subnet_id}"

				if !@server["vpc"]["nat_host_name"].nil? or !@server["vpc"]["nat_host_id"].nil?
					admin_sg = MU::Server.punchAdminNAT(@server, node)
				else
					admin_sg = MU::FirewallRule.setAdminSG(vpc_id: vpc_id, region: @server['region'])
				end

				instance_descriptor[:subnet_id] = subnet_id
				node_sg = MU::FirewallRule.createEc2SG(
						@server["name"].upcase,
						@server["ingress_rules"],
						description: "SG holes for #{node}",
						vpc_id: vpc_id,
						region: @server['region']
				)
			else
				admin_sg = MU::FirewallRule.setAdminSG(region: @server['region'])
				node_sg = MU::FirewallRule.createEc2SG(
						@server["name"].upcase,
						@server["ingress_rules"],
						description: "SG holes for #{node}",
						region: @server['region']
				)
			end
			security_groups = Array.new
			security_groups << admin_sg
			security_groups << node_sg
			if !@server["add_firewall_rules"].nil?
				@server["add_firewall_rules"].each { |acl|
					sg = MU::FirewallRule.find(sg_id: acl["rule_id"], name: acl["rule_name"], region: @server['region'])
					if sg.nil?
						MU.log "Couldn't find dependent security group #{acl} for server #{node}", MU::ERR
						raise MuError, "deploy failure"
					end
					security_groups << sg.group_id
				}
			end

			instance_descriptor[:security_group_ids] = security_groups

		  if !@userdata.nil? and !@userdata.empty?
		    instance_descriptor[:user_data] =  Base64.encode64(@userdata)
		  end

		  if !@server["iam_role"].nil?
		    instance_descriptor[:iam_instance_profile] = { name: @server["iam_role"]}
		  end

			configured_storage = Array.new
			if @server["storage"]
				@server["storage"].each { |vol|
					configured_storage << MU::Server.convertBlockDeviceMapping(vol)
				}
			end
		
			MU::Server.waitForAMI(@server["ami_id"], region: @server['region'])

			instance_descriptor[:block_device_mappings] = configured_storage
			instance_descriptor[:block_device_mappings].concat(@ephemeral_mappings)

			instance_descriptor[:monitoring] = { enabled: @server['monitoring'] }

			MU.log "Creating EC2 instance #{node}"
			MU.log "Instance details for #{node}: #{instance_descriptor}", MU::DEBUG
#				if instance_descriptor[:block_device_mappings].empty?
#					instance_descriptor.delete(:block_device_mappings)
#				end
#pp instance_descriptor[:block_device_mappings]
			retries = 0
			begin
				response = MU.ec2(@server['region']).run_instances(instance_descriptor)
			rescue Aws::EC2::Errors::InvalidGroupNotFound, Aws::EC2::Errors::InvalidSubnetIDNotFound, Aws::EC2::Errors::InvalidParameterValue, Aws::EC2::Errors::RequestLimitExceeded => e
				if retries < 10
					if retries > 7
						MU.log "Seeing #{e.inspect} while trying to launch #{node}, retrying a few more times...", MU::WARN, details: instance_descriptor
					end
					sleep 10
					retries = retries + 1
					retry
				else
					raise MuError, e.inspect
				end
			end

			instance = response.instances.first
			MU.log "#{node} (#{instance.instance_id}) coming online"


			return instance

		end

		# Given a Server configuration object, figure out what's needed to SSH into
		# it.
		# @param config [Hash]: A server's configuration block as defined in {MU::Config::BasketofKittens::servers}
		def self.getNodeSSHProxy(config)
      ssh_keydir = Etc.getpwuid(Process.uid).dir+"/.ssh"
			return nil if config.nil?

      nat_ssh_key=nat_ssh_user=nat_ssh_host = nil
      if config["vpc"] != nil
        if !config["vpc"]["nat_host_name"].nil? or
            !config["vpc"]["nat_host_id"].nil?
          nat_ssh_user = config["vpc"]["nat_ssh_user"]
          nat_instance, mu_name = MU::Server.find(
            id: config["vpc"]["nat_host_id"],
            name: config["vpc"]["nat_host_name"],
						region: config['region']
          )
          if nat_instance.nil?
            MU.log "#{config["name"]} (#{MU.mu_id}) is configured to use #{config['vpc']} but I can't find a running instance matching nat_host_id or nat_host_name", MU::ERR, details: caller
            raise MuError, "#{config["name"]} (#{MU.mu_id}) is configured to use #{config['vpc']} but I can't find a running instance matching nat_host_id or nat_host_name"
          end
          nat_ssh_key = nat_instance.key_name
          nat_ssh_host = nat_instance.public_ip_address
					found_servers = MU::MommaCat.getResourceDeployStruct(MU::Server.cfg_plural, name: mu_name)
					if !found_servers.nil? and found_servers.is_a?(Hash)
						if found_servers.values.first['instance_id'] == nat_instance.instance_id
							dns_name = MU::DNSZone.genericDNSEntry(found_servers.keys.first, nat_ssh_host, MU::Server, noop: true, sync_wait: config['dns_sync_wait'])
						end
					end
					nat_ssh_host = dns_name if !dns_name.nil?
        end
      end

      return [nat_ssh_key, nat_ssh_user, nat_ssh_host]

		end

		# Basic setup tasks performed on a new node during its first initial ssh
		# connection. Most of this is terrible Windows glue.
		# @param ssh [Net::SSH::Connection::Session]: The active SSH session to the new node.
		# @param server [Hash]: A server's configuration block as defined in {MU::Config::BasketofKittens::servers}
		def self.initialSSHTasks(ssh, server)
			chef_cleanup = %q{test -f /opt/mu_installed_chef || ( rm -rf /var/chef/ /etc/chef /opt/chef/ /usr/bin/chef-* ; touch /opt/mu_installed_chef )}
			win_env_fix = %q{echo 'export PATH="$PATH:/cygdrive/c/opscode/chef/embedded/bin"' > "$HOME/chef-client"; echo 'prev_dir="`pwd`"; for __dir in /proc/registry/HKEY_LOCAL_MACHINE/SYSTEM/CurrentControlSet/Control/Session\ Manager/Environment;do cd "$__dir"; for __var in `ls * | grep -v TEMP | grep -v TMP`;do __var=`echo $__var | tr "[a-z]" "[A-Z]"`; test -z "${!__var}" && export $__var="`cat $__var`" >/dev/null 2>&1; done; done; cd "$prev_dir"; /cygdrive/c/opscode/chef/bin/chef-client.bat $@' >> "$HOME/chef-client"; chmod 700 "$HOME/chef-client"; ( grep "^alias chef-client=" "$HOME/.bashrc" || echo 'alias chef-client="$HOME/chef-client"' >> "$HOME/.bashrc" ) ; ( grep "^alias mu-groom=" "$HOME/.bashrc" || echo 'alias mu-groom="powershell -File \"c:/Program Files/Amazon/Ec2ConfigService/Scripts/UserScript.ps1\""' >> "$HOME/.bashrc" )}
			win_set_pw = nil
			if !server['windows_admin_password'].nil?
				field = server["windows_admin_password"]["password_field"]
				pw = ChefVault::Item.load(
					server['windows_admin_password']['vault'],
					server['windows_admin_password']['item']
				)[field]
				win_set_pw = %Q{powershell -Command "&{ (([adsi]('WinNT://./#{server["windows_admin_username"]}, user')).psbase.invoke('SetPassword', '#{pw}'))}"}
			else
				begin
					win_set_pw = %Q{powershell -Command "&{ (([adsi]('WinNT://./#{server['windows_admin_username']}, user')).psbase.invoke('SetPassword', '#{MU.mommacat.fetchSecret(server["instance_id"], "winpass")}'))}"}
				rescue MU::MommaCat::SecretError
					# This is ok
				end
			end

			win_installer_check = %q{ls /proc/registry/HKEY_LOCAL_MACHINE/SOFTWARE/Microsoft/Windows/CurrentVersion/Installer/}
			win_set_hostname = %Q{powershell -Command "& {Rename-Computer -NewName "#{server['mu_windows_name']}" -Force -PassThru -Restart}"}
			# We sometimes get a machine that's already been integrated into AD, and
			# thus needs domain creds to rename. Use 'em if we have 'em.
			win_set_hostname_ad = nil
			if !server['active_directory'].nil?
				item = ChefVault::Item.load(
					server['active_directory']['auth_vault'],
					server['active_directory']['auth_item']
				)
				ad_user = item[server['active_directory']['auth_username_field']]
				ad_pwd = item[server['active_directory']['auth_password_field']]
				win_set_hostname_ad = %Q{powershell -Command "& {Rename-Computer -NewName "#{server['mu_windows_name']}" -Force -PassThru -Restart -DomainCredential(New-Object System.Management.Automation.PSCredential('femadata\\#{ad_user}', (ConvertTo-SecureString '#{ad_pwd}' -AsPlainText -Force)))}"}
			end

			begin
				if !server['set_windows_pass'] and !win_set_pw.nil?
					MU.log "Setting Windows password for user #{server['windows_admin_username']}", MU::NOTICE
					ssh.exec!(win_set_pw)
MU.log win_set_pw, MU::ERR
					server['set_windows_pass'] = true
				end
				if !server['cleaned_chef']
					MU.log "Expunging pre-existing Chef install, if we didn't create it", MU::NOTICE
					ssh.exec!(chef_cleanup)
					server['cleaned_chef'] = true
				end
				if %w{win2k12r2 win2k12 windows}.include? server['platform']
					output = ssh.exec!(win_env_fix)
					output = ssh.exec!(win_installer_check)
					if output.match(/InProgress/)
						raise BootstrapTempFail, "Windows Installer service is still doing something, need to wait"
					end
					if !server['hostname_set'] and !server['mu_windows_name'].nil?
						# XXX need a better guard here, this pops off every time
						ssh.exec!(win_set_hostname)
						ssh.exec!(win_set_hostname_ad) if !win_set_hostname_ad.nil?
						server['hostname_set'] = true
						raise BootstrapTempFail, "Setting hostname to #{server['mu_windows_name']}, possibly rebooting"
					end
				end
			rescue RuntimeError => e
				raise BootstrapTempFail, "Got #{e.inspect} performing initial SSH connect tasks, will try again"
			end
		end

		
		# Apply tags, bootstrap Chef, and other administravia for a new instance.
		# Return SSH configuration information for getting into said instance.
		# @param instance [OpenStruct]: The cloud provider's full descriptor for this instance.
		def groomEc2(instance)
			return MU::Server.groomEc2(@server, instance, @deploy.keypairname, environment: @deploy.environment, sync_wait: @server['dns_sync_wait'])
		end
		# (see #groomEc2)
		def self.groomEc2(server, instance, keypairname, environment: environment, sync_wait: sync_wait)
		  node = server['mu_name']
			if File.exists?(Etc.getpwuid(Process.uid).dir+"/.chef/knife.rb")
				Chef::Config.from_file(Etc.getpwuid(Process.uid).dir+"/.chef/knife.rb")
			end
			Chef::Config[:chef_server_url] = "https://#{MU.mu_public_addr}/organizations/#{MU.chef_user}"
			Chef::Config[:environment] = environment

			return false if !MU::MommaCat.lock(instance.instance_id+"-groom", true)
			return false if !MU::MommaCat.lock(instance.instance_id+"-deploy", true)

			MU::MommaCat.createStandardTags(instance.instance_id, region: server['region'])
		  MU::MommaCat.createTag(instance.instance_id, "Name", node, region: server['region'])
			if !server['tags'].nil?
				server['tags'].each { |tag|
					MU::MommaCat.createTag(instance.instance_id, tag['key'], tag['value'], region: server['region'])
				}
			end
			MU.log "Tagged #{node} (#{instance.instance_id}) with MU-ID=#{MU.mu_id}", MU::DEBUG


			retries = 0
			id = instance.instance_id
			begin
				if instance.nil? or instance.state.name != "running"
					if !instance.nil? and instance.state.name == "terminated"
						retries = 30
						raise MuError, "#{id} appears to have been terminated mid-bootstrap!"
					end
					if retries % 3 == 0
						MU.log "Waiting for EC2 instance #{node} to be ready...", MU::NOTICE
					end
					sleep 20
					instance, mu_name = MU::Server.find(id: id, region: server['region'])
				end
			rescue Aws::EC2::Errors::ServiceError => e
				if retries < 30
					MU.log "Got #{e.inspect} during initial instance creation of #{id}, retrying...", MU::NOTICE, details: instance
					retries = retries + 1
					sleep 5
					retry
				else
					raise MuError, "Too many retries creating #{node} (#{e.inspect})"
				end
			end while instance.nil? or (instance.state.name != "running" and retries < 30)

			admin_sg = MU::Server.punchAdminNAT(server, node)

			# Unless we're planning on associating a different IP later, set up a 
			# DNS entry for this thing and let it sync in the background. We'll come
			# back to it later.
			dnsthread = nil
			if server['static_ip'].nil?
				parent_thread_id = Thread.current.object_id
				dnsthread = Thread.new {
					MU.dupGlobals(parent_thread_id)
					if !instance.public_dns_name.nil? and !instance.public_dns_name.empty?
						MU::DNSZone.genericDNSEntry(node, instance.public_dns_name, MU::Server, sync_wait: sync_wait)
					else
						MU::DNSZone.genericDNSEntry(node, instance.private_ip_address, MU::Server, sync_wait: sync_wait)
					end
				}
			end

			begin
				if !server['src_dst_check'] and !server["vpc"].nil?
					MU.log "Disabling source_dest_check #{node} (making it NAT-worthy)"
					MU.ec2(server['region']).modify_instance_attribute(
						instance_id: instance.instance_id,
						source_dest_check: { :value => false }
					)
				end

				# Set console termination protection. Autoscale nodes won't set this
				# by default.
				MU.ec2(server['region']).modify_instance_attribute(
					instance_id: instance.instance_id,
					disable_api_termination: { :value => true }
				)
			rescue Aws::EC2::Errors::RequestLimitExceeded
				sleep 10
				retry
			end

			has_elastic_ip = false
			if !instance.public_ip_address.nil?
				begin
					resp = MU.ec2((server['region'])).describe_addresses(public_ips: [instance.public_ip_address])
					if resp.addresses.size > 0 and resp.addresses.first.instance_id == instance.instance_id
						has_elastic_ip = true
					end
				rescue Aws::EC2::Errors::RequestLimitExceeded
					sleep 10
					retry
				rescue Aws::EC2::Errors::InvalidAddressNotFound => e
					# XXX this is ok to ignore, it means the public IP isn't Elastic
				end
			end

			# Gather stuff we'll need for ssh'ing into this host
			ssh_keydir = Etc.getpwuid(Process.uid).dir+"/.ssh"
			node_ssh_key = keypairname
			node_ssh_user = server["ssh_user"]
			if !File.exist?(ssh_keydir+"/"+node_ssh_key)
				MU.log "Node #{node} ssh key #{ssh_keydir}/#{node_ssh_key} does not exist", MU::ERR
				raise MuError, "deploy failure"
			end

			nat_ssh_key, nat_ssh_user, nat_ssh_host = MU::Server.getNodeSSHProxy(server)
			if !nat_ssh_host.nil? and !MU::VPC.haveRouteToInstance?(instance.instance_id)
				MU.log "Connecting to #{node} through NAT instance #{nat_ssh_host}", MU::NOTICE
			end

			if !server["vpc"].nil?
				is_private = MU::VPC.isSubnetPrivate?(instance.subnet_id, region: server['vpc']['region'])
				if !is_private or (!server['static_ip'].nil? and !server['static_ip']['assign_ip'].nil?)
					if !server['static_ip'].nil?
						if !server['static_ip']['ip'].nil?
							public_ip = associateElasticIp(instance.instance_id, classic: false, ip: server['static_ip']['ip'])
						elsif !has_elastic_ip
							public_ip = associateElasticIp(instance.instance_id)
						end
					end
				end

				if !nat_ssh_key.nil? and !File.exist?(ssh_keydir+"/"+nat_ssh_key)
					MU.log "NAT proxy #{nat_ssh_host} ssh key #{ssh_keydir}/#{nat_ssh_key} does not exist", MU::ERR
					raise MuError, "deploy failure"
				end
				if is_private and !nat_ssh_host and !MU::VPC.haveRouteToInstance?(instance.instance_id)
					MU.log "#{node} is in a private subnet, but has no NAT host configured, and I have no other route to it", MU::ERR
					raise MuError, "#{node} is in a private subnet, but has no NAT host configured, and I have no other route to it"
				end

				# If we've asked for additional subnets (and this server is not a
				# member of a Server Pool, which has different semantics), create
				# extra interfaces to accomodate.
				if !server['vpc']['subnets'].nil? and server['basis'].nil?
					device_index = 1
					server['vpc']['subnets'].each { |subnet|
						tag_key, tag_value = server['vpc']['tag'].split(/=/, 2) if !server['vpc']['tag'].nil?
						existing_vpc, vpc_name = MU::VPC.find(
							id: server['vpc']['vpc_id'],
							name: server['vpc']['vpc_name'],
							deploy_id: server['vpc']['deploy_id'],
							tag_key: tag_key,
							tag_value: tag_value,
							region: server['vpc']['region']
						)
						tag_key, tag_value = server['vpc']['tag'].split(/=/, 2) if !subnet['tag'].nil?

						subnet_struct = MU::VPC::findSubnet(
							id: subnet["subnet_id"],
							name: subnet["subnet_name"],
							vpc_id: existing_vpc.vpc_id,
							deploy_id: server['vpc']['deploy_id'],
							tag_key: tag_key,
							tag_value: tag_value,
							region: server['vpc']['region']
						)
						if subnet_struct.nil?
							MU.log "#{node} is configured to have an interface in #{subnet}, but no such subnet exists", MU::ERR
							raise MuError, "deploy failure"
						end
						subnet_id = subnet_struct.subnet_id
						MU.log "Adding network interface on subnet #{subnet_id} for #{node}"
						begin
							iface = MU.ec2(server['region']).create_network_interface(subnet_id: subnet_id).network_interface
						rescue Aws::EC2::Errors::RequestLimitExceeded
							sleep 10
							retry
						end
						MU::MommaCat.createStandardTags(iface.network_interface_id, region: server['region'])
					  MU::MommaCat.createTag(iface.network_interface_id,"Name",node+"-ETH"+device_index.to_s, region: server['region'])
						if !server['tags'].nil?
							server['tags'].each { |tag|
								MU::MommaCat.createTag(iface.network_interface_id,tag['key'],tag['value'], region: server['region'])
							}
						end
						begin
							MU.ec2(server['region']).attach_network_interface(
								network_interface_id: iface.network_interface_id,
								instance_id: instance.instance_id,
								device_index: device_index
							)
						rescue Aws::EC2::Errors::RequestLimitExceeded
							sleep 10
							retry
						end
						device_index = device_index + 1
					}
				end
			elsif !server['static_ip'].nil?
				if !server['static_ip']['ip'].nil?
					public_ip = associateElasticIp(instance.instance_id, classic: true, ip: server['static_ip']['ip'])
				elsif !has_elastic_ip
					public_ip = associateElasticIp(instance.instance_id, classic: true)
				end
			end

			canonical_ip = public_ip if !public_ip.nil?

			if !server['image_then_destroy']
				MU::Server.notifyDeploy(server["name"], instance.instance_id, server, region: server['region'])
			end

		  MU.log "EC2 instance #{node} has id #{instance.instance_id}", MU::DEBUG

			instance, mu_name = MU::Server.find(id: instance.instance_id, region: server['region'])

			if !server['dns_records'].nil?
				server['dns_records'].each { |dnsrec|
					dnsrec['name'] = node.downcase if !dnsrec.has_key?('name')
				}
			end
			if !instance.public_dns_name.nil? and !instance.public_dns_name.empty?
				MU::DNSZone.createRecordsFromConfig(server['dns_records'], target: instance.public_ip_address)
			else
				MU::DNSZone.createRecordsFromConfig(server['dns_records'], target: instance.private_ip_address)
			end

			# If we haven't already, set a platform-mu DNS entry for this guy. It
			# can sync in the background until we're done with knife bootstrap.
			if dnsthread.nil?
				parent_thread_id = Thread.current.object_id
				dnsthread = Thread.new {
					MU.dupGlobals(parent_thread_id)
					if !instance.public_dns_name.nil? and !instance.public_dns_name.empty?
						MU::DNSZone.genericDNSEntry(node, instance.public_dns_name, MU::Server, sync_wait: sync_wait)
					else
						MU::DNSZone.genericDNSEntry(node, instance.private_ip_address, MU::Server, sync_wait: sync_wait)
					end
				}
			end

			server["private_dns_name"] = instance.private_dns_name
			server["public_dns_name"] = instance.public_dns_name
			server["private_ip_address"] = instance.private_ip_address
			server["public_ip_address"] = instance.public_ip_address

			ext_mappings = MU.structToHash(instance.block_device_mappings)

		  # Root disk on standard CentOS AMI
		  # tagVolumes(instance.instance_id, "/dev/sda", "Name", "ROOT-"+MU.mu_id+"-"+server["name"].upcase)
		  # Root disk on standard Ubuntu AMI
		  # tagVolumes(instance.instance_id, "/dev/sda1", "Name", "ROOT-"+MU.mu_id+"-"+server["name"].upcase)
		
		  # Generic deploy ID tag
		  # tagVolumes(instance.instance_id)

			# Tag volumes with all our standard tags. 
			# Maybe replace tagVolumes with this? There is one more place tagVolumes is called from
			begin
				volumes = MU.ec2(server['region']).describe_volumes(filters: [name: "attachment.instance-id", values: [instance.instance_id]])
				volumes.each {|vol|
					vol.volumes.each{ |volume|
						volume.attachments.each { |attachment|
							MU::MommaCat.listStandardTags.each_pair { |key, value|
								MU::MommaCat.createTag(attachment.volume_id, key, value, region: server['region'])

								if attachment.device == "/dev/sda" or attachment.device == "/dev/sda1"
									MU::MommaCat.createTag(attachment.volume_id, "Name", "ROOT-#{MU.mu_id}-#{server["name"].upcase}", region: server['region'])
								else
									MU::MommaCat.createTag(attachment.volume_id, "Name", "#{MU.mu_id}-#{server["name"].upcase}-#{attachment.device.upcase}", region: server['region'])
								end
							}

							if server['tags']
								server['tags'].each { |tag|
									MU::MommaCat.createTag(attachment.volume_id, tag['key'], tag['value'], region: server['region'])
								}
							end
						}
					}
				}
			rescue Aws::EC2::Errors::RequestLimitExceeded
				sleep 10
				retry
			end

		  ssh_retries=0
			canonical_name = instance.public_dns_name
			canonical_name = instance.private_dns_name if !canonical_name or nat_ssh_host != nil
			server['canonical_name'] = canonical_name

			canonical_ip = instance.public_ip_address if !canonical_ip
			canonical_ip = instance.private_ip_address if !canonical_ip or nat_ssh_host != nil
			server['canonical_ip'] = canonical_ip

			if canonical_ip.nil?
				MU.log "Failed to get an IP address out of #{instance.instance_id}", MU::ERR, details: instance
				raise MuError, "deploy failure"
			end

			if !server['add_private_ips'].nil?
				instance.network_interfaces.each { |int|
					if int.private_ip_address == instance.private_ip_address and int.private_ip_addresses.size < (server['add_private_ips'] + 1)
						MU.log "Adding #{server['add_private_ips']} extra private IP addresses to #{instance.instance_id}"
						begin
							MU.ec2(server['region']).assign_private_ip_addresses(
								network_interface_id: int.network_interface_id,
								secondary_private_ip_address_count: server['add_private_ips'],
								allow_reassignment: false
							)
						rescue Aws::EC2::Errors::RequestLimitExceeded
							sleep 10
							retry
						end
					end
				}
				MU::Server.notifyDeploy(server["name"], instance.instance_id, server, region: server['region'])
			end

			# Make an initial connection with SSH to see if this host is ready to
			# have Chef inflicted on it. Also run some prep.
			ssh_wait = 15 
			max_retries = 15
			if %w{win2k12r2 win2k12 windows}.include? server['platform']
				ssh_wait = 60
				max_retries = 25
			end
		  begin
				Thread.abort_on_exception = false
				loglevel = MU::DEBUG
				loglevel = MU::NOTICE if (ssh_retries % 3 == 0)
				ssh = MU::Server.getSSHSession(server, node_ssh_key, loglevel)
				initialSSHTasks(ssh, server)
		  rescue BootstrapTempFail, SystemCallError, Timeout::Error, Errno::EHOSTUNREACH, Net::SSH::Proxy::ConnectError, SocketError, Net::SSH::Disconnect, Net::SSH::AuthenticationFailed, Net::SSH::Disconnect => e
				loglevel = MU::DEBUG
				if ssh_retries % 3 == 0 or e.class.name == "MU::BootstrapTempFail"
					loglevel = MU::NOTICE
				end
		    ssh_retries += 1 if e.class.name != "MU::BootstrapTempFail"

		    if ssh_retries <= max_retries
					MU.log "SSH attempt ##{ssh_retries} of #{max_retries} for #{node} got #{e.inspect}, waiting #{ssh_wait}s before trying again.", loglevel
					sleep ssh_wait
		      retry
		    else
		      raise MuError, "Too many authentication/connection failures bootstrapping #{node}."
		    end
		  end

			# See if this node already exists in Chef. If it does, we're done.
			MU.log "Chef config", MU::DEBUG, details: Chef::Config.inspect
			nodelist = Chef::Node.list()
			if nodelist.has_key?(node)
				MU.log "Node #{node} has already been bootstrapped, skipping Chef setup.", MU::NOTICE
				saveInitialChefNodeAttrs(node, instance, server, canonical_ip)
				MU::MommaCat.unlock(instance.instance_id+"-groom")
				MU::MommaCat.unlock(instance.instance_id+"-deploy")
				return true
			end

		  MU.log "Bootstrapping #{node} (#{canonical_ip}) with knife"

			run_list = ["role[mu-node]"]

			require 'chef/knife'
			require 'chef/knife/ssh'
			require 'chef/knife/bootstrap'
			require 'chef/knife/core/bootstrap_context'
			require 'chef/knife/bootstrap_windows_ssh'

			json_attribs = {}
			if !server['application_attributes'].nil?
				json_attribs['application_attributes'] = server['application_attributes']
			end
			server['vault_access'] = [] if server['vault_access'].nil?

		  if server["platform"] != "windows" and server['platform'] != "win2k12" and server['platform'] != "win2k12r2"
				kb = Chef::Knife::Bootstrap.new([canonical_ip])
		    kb.config[:use_sudo] = true
		    kb.config[:distro] = 'chef-full'
		  else
		    kb = Chef::Knife::BootstrapWindowsSsh.new([canonical_ip])
		    kb.config[:cygwin] = true
		    kb.config[:distro] = 'windows-chef-client-msi'
		    kb.config[:node_ssl_verify_mode] = 'none'
		    kb.config[:node_verify_api_cert] = false
		  end
			if json_attribs.size > 1
				kb.config[:json_attribs] = JSON.generate(json_attribs)
			end
# XXX this seems to break Knife Bootstrap for the moment
#			if !server['vault_access'].nil?
#				v = {}
#				server['vault_access'].each { |vault|
#					v[vault['vault']] = [] if v[vault['vault']].nil?
#					v[vault['vault']] << vault['item']
#				}
#				kb.config[:bootstrap_vault_json] = JSON.generate(v)
#			end
	    kb.config[:run_list] = run_list
	    kb.config[:ssh_user] = node_ssh_user
	    kb.config[:forward_agent] = node_ssh_user
		  kb.name_args = "#{canonical_ip}"
		  kb.config[:chef_node_name] = node
		  kb.config[:bootstrap_version] = MU.chefVersion
# XXX key off of MU verbosity level
			kb.config[:log_level] = :debug
			kb.config[:identity_file] = ssh_keydir+"/"+node_ssh_key
			if !nat_ssh_host.nil?
				kb.config[:ssh_gateway] = nat_ssh_user+"@"+nat_ssh_host
			end
			# This defaults to localhost for some reason sometimes. Brute-force it.
		
		  MU.log "Knife Bootstrap settings for #{node} (#{canonical_ip})", MU::NOTICE, details: kb.config

			retries = 0
			begin
				# A Chef bootstrap shouldn't take this long, but we get these random
				# inexplicable hangs sometimes.
				Timeout::timeout(600) {	
				  kb.run
				}
			rescue Net::SSH::Disconnect, Errno::EPIPE, IOError, SystemExit, Timeout::Error, SocketError, Net::HTTPServerException => e
				if retries < 10
					retries = retries + 1
					MU.log "#{node}: Knife Bootstrap failed #{e.inspect}, retrying (#{retries} of 10)", MU::WARN
					sleep 10
					retry
				else
					raise MuError, "#{node}: Knife Bootstrap failed too many times with #{e.inspect}"
				end
			end

			dnsthread.join if !dnsthread.nil?

			MU::MommaCat.removeHostFromSSHConfig(node)
			if !server["vpc"].nil?
				if MU::VPC.haveRouteToInstance?(instance.instance_id)
					MU::MommaCat.addHostToSSHConfig(
						node,
						instance.private_ip_address,
						instance.private_dns_name,
						user: node_ssh_user,
						public_dns: instance.public_dns_name,
						public_ip: instance.public_ip_address,
						key_name: node_ssh_key
					)
				elsif is_private
					MU::MommaCat.addHostToSSHConfig(
						node,
						instance.private_ip_address,
						instance.private_dns_name,
						user: node_ssh_user,
						gateway_ip: nat_ssh_host,
						gateway_user: nat_ssh_user,
						key_name: node_ssh_key,
					)
				else
					MU::MommaCat.addHostToSSHConfig(
						node,
						instance.private_ip_address,
						instance.private_dns_name,
						public_dns: instance.public_dns_name,
						public_ip: instance.public_ip_address,
						user: node_ssh_user,
						key_name: node_ssh_key,
						gateway_user: nat_ssh_user,
						gateway_ip: nat_ssh_host,
					)
				end
			else
				MU::MommaCat.addHostToSSHConfig(
					node,
					instance.private_ip_address,
					instance.private_dns_name,
					user: node_ssh_user,
					public_dns: instance.public_dns_name,
					public_ip: instance.public_ip_address,
					key_name: node_ssh_key
				)
			end


			# Manufacture a generic SSL certificate, signed by the Mu server, for
			# consumption by various node services (Apache, Splunk, etc).
			MU.log "Creating self-signed service SSL certificate for #{node} (CN=#{canonical_ip})"
	
			# Create and save a key
			key = OpenSSL::PKey::RSA.new 4096
			if !Dir.exist?(MU.mySSLDir)
				Dir.mkdir(MU.mySSLDir, 0700)
			end
			open("#{MU.mySSLDir}/#{node}.key", 'w', 0600) { |io|
				io.write key.to_pem
			}

			# Create a certificate request for this node
			csr = OpenSSL::X509::Request.new
			csr.version = 0
			csr.subject = OpenSSL::X509::Name.parse "CN=#{canonical_ip}/O=Mu/C=US"
			csr.public_key = key.public_key
			open("#{MU.mySSLDir}/#{node}.csr", 'w', 0644) { |io|
				io.write csr.to_pem
			}


			if MU.chef_user == "mu"
				MU.mommacat.signSSLCert("#{MU.mySSLDir}/#{node}.csr")
			else
				deploykey = OpenSSL::PKey::RSA.new(MU.mommacat.public_key)
				deploysecret = Base64.urlsafe_encode64(deploykey.public_encrypt(MU.mommacat.deploy_secret))
				res_type = "server"
				res_type = "server_pool" if !server['basis'].nil?
				uri = URI("https://#{MU.mu_public_addr}:2260/")
				req = Net::HTTP::Post.new(uri)
				req.set_form_data(
					"mu_id" => MU.mu_id,
					"mu_resource_name" => server['name'],
					"mu_resource_type" => res_type,
					"mu_ssl_sign" => "#{MU.mySSLDir}/#{node}.csr",
					"mu_user" => MU.chef_user,
					"mu_deploy_secret" => deploysecret
				)
				http = Net::HTTP.new(uri.hostname, uri.port)
				http.ca_file = "/etc/pki/Mu_CA.pem" # XXX why no worky?
				http.use_ssl = true
				http.verify_mode = OpenSSL::SSL::VERIFY_NONE
				response = http.request(req)
				if response.code != "200"
					MU.log "Got error back on signing request for #{MU.mySSLDir}/#{node}.csr", MU::ERR
				end
			end

			cert = OpenSSL::X509::Certificate.new File.read "#{MU.mySSLDir}/#{node}.crt"

			# Upload the certificate to a Chef Vault for this node
			vault_cmd = "#{MU::Config.knife} vault create #{node} ssl_cert '{ \"data\": { \"node.crt\":\"#{cert.to_pem.chomp!.gsub(/\n/, "\\n")}\", \"node.key\":\"#{key.to_pem.chomp!.gsub(/\n/, "\\n")}\" } }' #{MU::Config.vault_opts} --search name:#{node}"
			MU.log vault_cmd, MU::DEBUG
			puts `#{vault_cmd}`
			server['vault_access'] << { "vault"=> node, "item" => "ssl_cert" }

			# Any and all 'secrets' parameters should also be stuffed into our vault.
			if !server['secrets'].nil?
				json = JSON.generate(server['secrets'])
				vault_cmd = "#{MU::Config.knife} vault create #{node} secrets '#{json}' #{MU::Config.vault_opts} --search name:#{node}"
				MU.log vault_cmd, MU::DEBUG
				puts `#{vault_cmd}`
				server['vault_access'] << { "vault"=> node, "item" => "secrets" }
			end

			saveInitialChefNodeAttrs(node, instance, server, canonical_ip)
			MU::MommaCat.openFirewallForClients

			# Remove one-shot bootstrap recipes from the node's final run list
			["mu-tools::newclient"].each { |recipe|
				begin
					Chef::Knife.run(['node', 'run_list', 'remove', node, "recipe[#{recipe}]"], {})
				rescue SystemExit => e
					MU.log "#{node}: Run list removal of recipe[#{recipe}] failed with #{e.inspect}", MU::ERR
				end
			}


			# Join this node to its Active Directory domain, if applicable. This will
			# trigger a reboot on Windows nodes, because what doesn't?
			if !server['active_directory'].nil?
				if server['mu_windows_name'].nil?
					server['mu_windows_name'] = MU::MommaCat.getResourceName(server['name'], max_length: 15, need_unique_string: true)
					MU::Server.saveInitialChefNodeAttrs(node, instance, server, canonical_ip)
				end
				MU::Server.knifeAddToRunList(node, "recipe[mu-tools::ad-client]");
				MU::Server.runChef(node, server, node_ssh_key, "Join Active Directory")
			end

			MU::MommaCat.unlock(instance.instance_id+"-deploy")
			MU::MommaCat.unlock(instance.instance_id+"-groom")
			return true
		end

		# Save common MU attributes to this node's Chef node structure.
		# @param node [String]: The node's (Chef) name.
		# @param instance [OpenStruct]: The cloud provider's full descriptor for this instance.
		# @param server [Hash]: The full {MU::Config} resource declaration as defined in {MU::Config::BasketofKittens::servers}
		# @param canonical_ip [String]: The node's "real" IP address for purposes of the outside world.
		def self.saveInitialChefNodeAttrs(node, instance, server, canonical_ip)
			MU.log "Saving #{node} Chef artifacts"
		  chef_node = Chef::Node.load(node)
			# Figure out what this node thinks its name is
		  system_name = chef_node['fqdn']
			MU.log "#{node} local name is #{system_name}", MU::DEBUG

		  chef_node.normal.app = server['application_cookbook'] if server['application_cookbook'] != nil
		  chef_node.normal.service_name = server["name"]
			chef_node.normal.windows_admin_username = server['windows_admin_username']
		  chef_node.chef_environment = MU.environment.downcase

			# If AD integration has been requested for this node, give Chef what it'll
			# need for mu-tools::ad-client to work.
			if !server['active_directory'].nil?
				chef_node.normal.ad.computer_name = server['mu_windows_name']
				chef_node.normal.ad.node_class = server['name']
				chef_node.normal.ad.domain_name = server['active_directory']['domain_name']
				chef_node.normal.ad.netbios_name = server['active_directory']['short_domain_name']
				chef_node.normal.ad.computer_ou = server['active_directory']['computer_ou'] if server['active_directory'].has_key?('computer_ou')
				chef_node.normal.ad.dcs = server['active_directory']['domain_controllers']
				chef_node.normal.ad.auth_vault = server['active_directory']['auth_vault']
				chef_node.normal.ad.auth_item = server['active_directory']['auth_item']
				chef_node.normal.ad.auth_username_field = server['active_directory']['auth_username_field']
				chef_node.normal.ad.auth_password_field = server['active_directory']['auth_password_field']
			end

			# Amazon-isms
			awscli_region_widget = {
				"compile_time" => true,
				"config_profiles" => {
					"default" => {
						"options" => {
							"region" => server['region']
						}
					}
				}
			}
			chef_node.normal.awscli = awscli_region_widget
		  chef_node.normal.ec2 = MU.structToHash(instance)
			chef_node.normal.cloudprovider = "ec2"
			tags = MU::MommaCat.listStandardTags
			if !server['tags'].nil?
				server['tags'].each { |tag|
					tags[tag['key']] = tag['value']
				}
			end
			chef_node.normal.tags = tags
		  chef_node.save

			# Finally, grant us access to some pre-existing Vaults.
			if !server['vault_access'].nil?
				retries = 0
				server['vault_access'].each { |vault|
					MU::MommaCat.lock("vault-"+vault['vault'], false, true)
					begin
						retries = retries + 1
						vault_cmd = "#{MU::Config.knife} vault update #{vault['vault']} #{vault['item']} #{MU::Config.vault_opts} --search name:#{node} 2>&1"
						MU.log "ADD attempt #{retries} enabling #{node} for vault access to #{vault['vault']} #{vault['item']} using command  #{vault_cmd}", MU::DEBUG
						output = `#{vault_cmd}`
                        MU.log "Result of ADD attempt #{retries} enabling #{node} for vault access to #{vault} was #{output} with RC #{$?.exitstatus}", MU::DEBUG
						if $?.exitstatus != 0
							MU.log "Got bad exit code on try #{retries} from knife vault update #{vault['vault']} #{vault['item']} #{MU::Config.vault_opts} --search name:#{node}", MU::WARN, details: output
						end
						# Check and see if what we asked for actually got done
						vault_cmd = "#{MU::Config.knife} vault show #{vault['vault']} #{vault['item']} clients -p clients -f yaml #{MU::Config.vault_opts} 2>&1"
						#MU.log vault_cmd, MU::DEBUG
						output = `#{vault_cmd}`
						MU.log "VERIFYING #{node} access to #{vault['vault']} #{vault['item']}:\n #{output}", MU::DEBUG
						if !output.match(/#{node}/)
							MU.log "Didn't see #{node} in output of #{vault_cmd}, trying again...", MU::WARN, details: output
							if retries < 10
								MU::MommaCat.unlock("vault-"+vault['vault'])
								sleep 5
								redo
							else
								MU.log "ABORTING: Unable to add #{node} to #{vault['vault']} #{vault['item']}, instance unlikely to operate correctly!", MU::ERR
								raise MuError, "Unable to add node #{node} to #{vault['vault']} #{vault['item']}, aborting"
							end
						else
							MU.log "Granting #{node} access to #{vault['vault']} #{vault['item']} after #{retries} retries", MU::NOTICE
							retries = 0
						end
					end
					MU::MommaCat.unlock("vault-"+vault['vault'])
				}
			end

			mu_zone, junk = MU::DNSZone.find(name: "mu")
			if !mu_zone.nil?
				if !instance.public_dns_name.nil? and !instance.public_dns_name.empty?
					MU::DNSZone.genericDNSEntry(node, instance.public_dns_name, MU::Server, sync_wait: @server['dns_sync_wait'])
				else
					MU::DNSZone.genericDNSEntry(node, instance.private_ip_address, MU::Server, sync_wait: @server['dns_sync_wait'])
				end
			else
				MU::MommaCat.removeInstanceFromEtcHosts(node)
				if system_name != "localhost" and
						system_name != instance.public_dns_name and
						system_name != instance.private_dns_name
					MU::MommaCat.addInstanceToEtcHosts(canonical_ip, node, system_name)
				else
					MU::MommaCat.addInstanceToEtcHosts(canonical_ip, node)
				end
			end
		end

		# Locate a running instance. Can identify instances by their cloud
		# provider identifier, OR by their internal Mu resource name, OR by a 
		# cloud provider tag name/value pair, OR by an assigned IP address.
		# @param name [String]: An Mu resource name, usually the 'name' field of aa Basket of Kittens resource declaration. Will search the currently loaded deployment unless another is specified.
		# @param deploy_id [String]: The deployment to search using the 'name' parameter.
		# @param id [String]: The cloud provider's identifier for this resource.
		# @param tag_key [String]: A tag key to search.
		# @param tag_value [String]: The value of the tag specified by tag_key to match when searching by tag.
		# @param allow_multi [Boolean]: When searching by tags or name, permit an array of resources to be returned (if applicable) instead of just one.
		# @param ip [String]: An IP address assigned to this instance.
		# @param region [String]: The cloud provider region
		# @return [OpenStruct,String]: The cloud provider's complete description of this server, and its MU resource name (if applicable).
		def self.find(name: nil, deploy_id: MU.mu_id, id: nil, tag_key: "Name", tag_value: nil, allow_multi: false, ip: nil, region: MU.curRegion)
			return nil if !id and !name and !ip and !tag_value
			# If we got an instance id, go get that
			instance = nil
			if !region.nil?
				regions = [region]
			else
				regions = MU::Config.listRegions
			end

			found_instances = []
			search_semaphore = Mutex.new
			search_threads = []

			if !id.nil?
				regions.each { |region|
					search_threads << Thread.new(region) { |myregion|
						MU.log "Hunting for instance with cloud id '#{id}' in #{myregion}", MU::DEBUG
						retries = 0
						begin
							response = MU.ec2(myregion).describe_instances(
								instance_ids: [id],
								filters: [
									{ name: "instance-state-name", values: ["running", "pending"] }
								]
							).reservations.first
							if response
								search_semaphore.synchronize {
									found_instances << response.instances.first
								}
							end
						rescue Aws::EC2::Errors::RequestLimitExceeded
							sleep 10
							retry
						rescue Aws::EC2::Errors::InvalidInstanceIDNotFound => e
							if retries < 5
								retries = retries + 1
								sleep 5
							else
								raise MuError, "#{e.inspect} in region #{region}"
							end
						end
					}
				}
				done_threads = []
				begin
					search_threads.each { |t|
						joined = t.join(2)
						done_threads << joined if !joined.nil?
					}
				end while found_instances.size < 1 and done_threads.size != search_threads.size
			end

			instance = found_instances.shift if found_instances.size > 0

			# Ok, well, let's try looking it up by IP then
			if instance.nil? and !ip.nil?
				MU.log "Hunting for instance by IP '#{ip}'", MU::DEBUG
				["ip-address", "private-ip-address"].each { |filter|
					begin
						response = MU.ec2(region).describe_instances(
							filters: [
								{ name: filter, values: [ip] },
								{ name: "instance-state-name", values: ["running", "pending"] }
							]
						).reservations.first
					rescue Aws::EC2::Errors::RequestLimitExceeded
						sleep 10
						retry
					end
					instance = response.instances.first if !response.nil?
				}
			end

			# Let's say we've found this instance with the cloud id or IP. Let's go
			# get its Mu resource name and return that too, if there is one.
			if !instance.nil? and name.nil?
				servers = MU::MommaCat.getResourceDeployStruct(cfg_plural, deploy_id: deploy_id)
				if !servers.nil?
					servers.each { |ext_server|
						if ext_server.values.size > 0 and ext_server.values.first['instance_id'] == instance.instance_id
							name = ext_server.values.first['#MU_NODE_CLASS']
							break
						end
					}
				end
			end

			return [instance, name] if !instance.nil?

			# If we've been asked to find by name, things get weird. In server pools
			# you can easily have multiple servers with the same Mu resource name.
			name_matches = []
			if !name.nil? and !deploy_id.nil?
				resource = MU::MommaCat.getResourceDeployStruct(cfg_plural, name: name, deploy_id: deploy_id)
				MU.log "Searching for instance by name '#{name}'", MU::DEBUG, details: resource
				if !resource.nil? and resource.keys.size == 1
					nodename, server = resource.shift
					name_matches << server
				elsif !resource.nil? and resource.keys.size > 1
					if !allow_multi
						MU.log "Found multiple matching servers for name #{name} in deploy #{deploy_id}", MU::ERR, details: resource
						raise MuError, "Found multiple matching servers for name #{name} in deploy #{deploy_id}"
					else
						resource.each_pair { |nodename, server|
							name_matches << server
						}
					end
				end
			end
			matches = []
			name_matches.each { |server|
				begin
					response = MU.ec2(region).describe_instances(
						instance_ids: [server['instance_id']],
						filters: [
							{ name: "instance-state-name", values: ["running", "pending"] }
						]
					).reservations.first
				rescue Aws::EC2::Errors::RequestLimitExceeded
					sleep 10
					retry
				end
				matches << response.instances.first if response
			}

			# Fine, let's try it by tag.
			if matches.size == 0 and !tag_value.nil?
				MU.log "Searching for instance by tag '#{tag_key}=#{tag_value}'", MU::DEBUG
				begin
					resp = MU.ec2(region).describe_instances(
						filters:[
							{ name: "tag:#{tag_key}", values: [tag_value] },
							{ name: "instance-state-name", values: ["running", "pending"] }
						]
					).reservations.first
				rescue Aws::EC2::Errors::RequestLimitExceeded
					sleep 10
					retry
				end
				if !resp.nil? and resp.instances.size == 1
					matches << resp.instances.first if resp
				elsif resp.instances.size > 1
					if !allow_multi
						MU.log "Found multiple matching servers for tag #{tag_key}=#{tag_value} in deploy #{deploy_id}", MU::ERR, details: resp
						raise MuError, "Found multiple matching servers for tag #{tag_key}=#{tag_value} in deploy #{deploy_id}"
					else
						matches = resp.instances
					end
				end
			end

			if allow_multi
				return [matches, name]
			else
				return [matches.first, name]
			end
		end

		# Fetch an instance by its id and log metadata to our deployment structure.
		# @param name [String]: The MU resource name of the instance.
		# @param instance_id [String]: The cloud provider's identifier for the instance.
		# @param region [String]: The cloud provider region
		# @param chef_data [Hash]: Optional data from Chef.
		def self.notifyDeploy(name, instance_id, server = nil, region: MU.curRegion, chef_data: {})
			begin
				response = MU.ec2(region).describe_instances(instance_ids: [instance_id]).reservations.first
			rescue Aws::EC2::Errors::RequestLimitExceeded
				sleep 10
				retry
			end
			instance = response.instances.first
			interfaces = Array.new

			private_ips = []
			instance.network_interfaces.each { |iface|
				iface.private_ip_addresses .each { |priv_ip|
					private_ips << priv_ip.private_ip_address
				}
				interfaces << {
					"network_interface_id" => iface.network_interface_id,
					"subnet_id" => iface.subnet_id,
					"vpc_id" => iface.vpc_id
				}
			}

			if !MU::Deploy.deployment["servers"].nil? and !MU::Deploy.deployment["servers"][name].nil?
				deploydata = MU::Deploy.deployment["servers"][name].dup
			else
				deploydata = Hash.new
			end

			node = server['mu_name']
			deploydata[node] = {
				"nodename" => server['mu_name'],
				"run_list" => server['run_list'],
				"iam_role" => server['iam_role'],
				"instance_id" => instance_id,
				"private_dns_name" => instance.private_dns_name,
				"public_dns_name" => instance.public_dns_name,
				"private_ip_address" => instance.private_ip_address,
				"public_ip_address" => instance.public_ip_address,
				"private_ip_list" => private_ips,
				"key_name" => instance.key_name,
				"subnet_id" => instance.subnet_id,
				"instance_type" => instance.instance_type#,
#				"network_interfaces" => interfaces,
#				"config" => server
			}

			if !server['mu_windows_name'].nil?
				deploydata[node]["mu_windows_name"] = server['mu_windows_name']
			end
			if !chef_data.nil?
				deploydata[node].merge!(chef_data)
			end
			deploydata[node]["region"] = region if !region.nil?

			MU::Deploy.notify("servers", name, deploydata)

			return deploydata
		end

		# If the specified server is in a VPC, and has a NAT, make sure we'll
		# be letting ssh traffic in from said NAT.
		# @param server [Hash]: The MU resource descriptor for this instance.
		# @param node [String]: The full Mu name for this instance.
		def self.punchAdminNAT(server, node)
			if !server["vpc"].nil?
				vpc_id, subnet_ids, nat_host_name, nat_ssh_user = MU::VPC.parseVPC(server['vpc'])
				if !nat_host_name.nil?
					nat_instance, mu_name = MU::Server.find(
						id: server["vpc"]["nat_host_id"],
						name: server["vpc"]["nat_host_name"],
						region: server['region']
					)
					if nat_instance.nil?
						MU.log "#{node} (#{MU.mu_id}) is configured to use #{server['vpc']} but I can't find a running instance matching nat_host_id or nat_host_name", MU::ERR
						raise MuError, "deploy failure"
					end
					MU.log "Adding administrative holes for NAT host #{nat_instance["private_ip_address"]} to #{node}", MU::DEBUG
					return MU::FirewallRule.setAdminSG(
						vpc_id: vpc_id,
						add_admin_ip: nat_instance["private_ip_address"],
						region: server['region']
					)
				end
			end
		end

		# Called automatically by {MU::Deploy#createResources}
		def deploy
			if !@deploy.mommacat_boot
				keypairname, ssh_private_key, ssh_public_key = @deploy.createEc2SSHKey
				return MU::Server.deploy(@server, @deploy.deployment, environment: @deploy.environment, keypairname: keypairname)
			end
		end
		# (see #deploy)
		def self.deploy(server, deployment, environment: environment, keypairname: keypairname, chef_rerun_only: chef_rerun_only = false)
			if server["instance_id"].nil?
				MU.log "MU::Server.deploy was called without an instance id", MU::ERR
				raise MuError, "MU::Server.deploy was called without an instance id"
			end
			MU::MommaCat.lock(server["instance_id"]+"-deploy")

			node = server['mu_name']

			if node.nil? or node.empty?
				MU.log "MU::Server.deploy was called without a mu_name", MU::ERR, details: server
				raise MuError, "MU::Server.deploy was called without a mu_name"
			end

			Chef::Config[:chef_server_url] = "https://#{MU.mu_public_addr}/organizations/#{MU.chef_user}"
			Chef::Config[:environment] = environment

			nat_ssh_key, nat_ssh_user, nat_ssh_host = MU::Server.getNodeSSHProxy(server)
			admin_sg = MU::Server.punchAdminNAT(server, node)

			ssh_keydir = Etc.getpwuid(Process.uid).dir+"/.ssh"

			if !chef_rerun_only
				instance, mu_name = MU::Server.find(id: server["instance_id"], region: server['region'])
				tagVolumes(server["instance_id"])
			        
			  # If we depend on database instances, make sure those database instances'
			  # security groups will let us in.
				if server["dependencies"] != nil then
					server["dependencies"].each { |dependent_on|
						if dependent_on['type'] != nil and dependent_on['type'] == "database" then
							database = MU::Database.find(name: dependent_on["name"], region: server["region"])
							if database.nil?
								MU.log "Couldn't find identifier for dependent database #{dependent_on['name']} in #{server["region"]}", MU::ERR
								raise MuError, "Couldn't find identifier for dependent database #{dependent_on['name']} in #{server["region"]}"
							end
							db_id = database.db_instance_identifier
							private_ip = server['private_ip_address']
							if private_ip != nil and db_id != nil then
								MU.log "Adding #{private_ip}/32 to database security groups for #{db_id}"
								MU::Database.allowHost("#{private_ip}/32", db_id, region: server['region'])
							end
						end
					}
				end

			  # If we have a loadbalancer configured, attach us to it
				# XXX refactor this into the LoadBalancer resource
				if !server['loadbalancers'].nil?
					server['loadbalancers'].each { |lb|
						lb_res = MU::LoadBalancer.find(
							name: lb['concurrent_load_balancer'],
							dns_name: lb["existing_load_balancer"],
							region: server['region']
						)
						raise MuError, "I need a LoadBalancer named #{lb['concurrent_load_balancer']}" if lb_res.nil?
						MU::LoadBalancer.registerInstance(lb_res.load_balancer_name, server["instance_id"], region: server['region'])
					}
				end

				if !server["run_list"].nil?
					server["run_list"].each do |rl_entry|
						MU::Server.knifeAddToRunList(node, rl_entry);
					end
				end

				saveDeploymentToChef(node)

				chef_node = Chef::Node.load(node)

				if server["application_attributes"] != nil then
					MU.log("Setting node:#{node} application_attributes to #{server['application_attributes']}", MU::DEBUG)
					chef_node.normal.application_attributes=server["application_attributes"]
				end

				chef_node.save

				# Make double sure we don't lose a cached mu_windows_name value.
				if %w{win2k12r2 win2k12 windows}.include?(server['platform']) or !server['active_directory'].nil?
					if !server['mu_windows_name'] and
							!deployment.nil? and deployment.has_key?('servers') and
							deployment['servers'].has_key?(server['name']) and
							deployment['servers'][server['name']].has_key?(node)
						server['mu_windows_name'] = deployment['servers'][server['name']][node]['mu_windows_name']
					end
				end

			end

			begin
				MU::Server.runChef(node, server, keypairname, "Full Initial Run")
			rescue ChefRunFail
				MU.log "Proceeding after failed initial Chef run, but #{node} may not behave as expected!", MU::WARN
			end
			if !chef_rerun_only
				MU::MommaCat.syncSiblings(server["name"], true, triggering_node: node)
				saveDeploymentToChef(node) if !server['sync_siblings']
			end


			# XXX this whole section possibly covered by MU::MommaCat.syncSiblings
			chef_node = Chef::Node.load(node)
			chef_data = Hash.new
			chef_data = chef_node.normal['deployment']['servers'][server['name']][node]
			if !chef_data.nil? and chef_data.size > 0 and !chef_rerun_only
				MU.log "Merging Chef data into deployment struct for #{node}", MU::DEBUG, details: chef_data
				MU::Server.notifyDeploy(server["name"], instance.instance_id, server, region: server['region'], chef_data: chef_data)
				saveDeploymentToChef(node)
			end

			if server['create_ami'] and !chef_rerun_only
				if server['image_then_destroy']
					# XXX ugh, man, this is incomplete
					knife_args = ['ssh', '-m', node, "rm -rf /etc/chef /root/.ssh/authorized_keys ; sed -i 's/^HOSTNAME=.*//' /etc/sysconfig/network"]
					begin
						Chef::Knife.run(knife_args, {})
					rescue SystemExit => e
						MU.log "Error scouring #{node} for AMI generation: #{e.message}", MU::ERR, details: e.backtrace
					end
				end
				ami_id = MU::Server.createImage(name: name = server['name'],
															instance_id: instance_id = server['instance_id'],
															storage: server['storage'],
															exclude_storage: server['image_exclude_storage'],
															region: server['region'])
				if server['image_then_destroy']
					waitForAMI(ami_id, region: server['region'])
					MU.log "AMI ready, removing source node #{node}"
					MU::Server.terminateInstance(id: server["instance_id"])
					%x{#{MU::Config.knife} node delete -y #{node}};
					return
				end
			end

			MU::MommaCat.unlock(server["instance_id"]+"-deploy")
		end

		# Synchronize the deployment structure managed by {MU::MommaCat} to Chef,
		# so that nodes can access this metadata.
		# @param node [String]: The node (Chef name) to save.
		# @param deployment [Hash]: The deployment metadata to save to the node.
		# @return [void]
		def self.saveDeploymentToChef(node, deployment = MU.mommacat.deployment)
			begin
				chef_node = Chef::Node.load(node)

				MU.log "Updating node: #{node} deployment attributes", details: deployment
				chef_node.normal.deployment.merge!(deployment)

				chef_node.save
			rescue Net::HTTPServerException => e
				MU.log "Attempted to save deployment to Chef node #{node} before it was bootstrapped.", MU::DEBUG
			end
		end

		# Create an AMI out of a running server. Requires either the name of a MU resource in the current deployment, or the cloud provider id of a running instance.
		# @param name [String]: The MU resource name of the server to use as the basis for this image.
		# @param instance_id [String]: The cloud provider resource identifier of the server to use as the basis for this image.
		# @param storage [Hash]: The storage devices to include in this image.
		# @param exclude_storage [Boolean]: Do not include the storage device profile of the running instance when creating this image.
		# @param region [String]: The cloud provider region
		# @return [String]: The cloud provider identifier of the new machine image.
		def self.createImage(name: name,
													instance_id: instance_id,
													storage: storage,
													exclude_storage: exclude_storage,
													region: MU.curRegion)

		  node = MU::MommaCat.getResourceName(name)
			ami_descriptor = {
				:instance_id => instance_id,
				:name => node,
				:description => "Image automatically generated by Mu from deployment of #{node}"
			}

			storage_list = Array.new
			if exclude_storage
				instance, mu_name = MU::Server.find(id: instance_id, region: region)
				instance.block_device_mappings.each { |vol|
					if vol.device_name != instance.root_device_name 
						storage_list << MU::Server.convertBlockDeviceMapping(
							{
								"device" => vol.device_name,
								"no-device" => ""
							}
						)
					end
				}
			elsif !storage.nil?
				storage.each { |vol|
					storage_list << MU::Server.convertBlockDeviceMapping(vol)
				}
			end
			ami_descriptor[:block_device_mappings] = storage_list
			if !exclude_storage
				ami_descriptor[:block_device_mappings].concat(@ephemeral_mappings)
			end
			MU.log "Creating AMI from #{node}", details: ami_descriptor
			begin
				resp = MU.ec2(region).create_image(ami_descriptor)
			rescue Aws::EC2::Errors::RequestLimitExceeded
				sleep 10
				retry
			rescue Aws::EC2::Errors::InvalidAMINameDuplicate => e
				MU.log "AMI #{node} already exists, skipping", MU::WARN
				return nil
			end
			MU.log "AMI of #{node} is #{resp.data.image_id}"
			MU::MommaCat.createStandardTags(resp.data.image_id, region: region)
		  MU::MommaCat.createTag(resp.data.image_id, "Name", node, region: region)
#						if !server['tags'].nil?
#							server['tags'].each { |tag|
#								MU::MommaCat.createTag(iface.network_interface_id,tag['key'],tag['value'])
#							}
#						end
			MU::Deploy.notify("images", name, { "image_id" => resp.data.image_id })
			return resp.data.image_id
		end

		# Given a cloud platform identifier for a machine image, wait until it's
		# flagged as ready.
		# @param image_id [String]: The machine image to wait for.
		# @param region [String]: The cloud provider region
		def self.waitForAMI(image_id, region: MU.curRegion)
			MU.log "Checking to see if AMI #{image_id} is available", MU::DEBUG
			begin
				images = MU.ec2.describe_images(image_ids: [image_id]).images
				if images.nil? or images.size == 0
					raise MuError, "No such AMI #{image_id} found"
				end
				state = images.first.state
				if state == "failed"
					raise MuError, "#{image_id} is marked as failed! I can't use this."
				end
				if state != "available"
					MU.log "Waiting for AMI #{image_id} (#{state})", MU::NOTICE
					sleep 60
				end
			rescue Aws::EC2::Errors::RequestLimitExceeded
				sleep 10
				retry
			end while state != "available"
			MU.log "AMI #{image_id} is ready", MU::DEBUG
		end

		# Maps our configuration language's 'storage' primitive to an Amazon-style
		# block_device_mapping.
		# @param storage [Hash]: The {MU::Config}-style storage description.
		# @return [Hash]: The Amazon-style storage description.
		def self.convertBlockDeviceMapping(storage)
			vol_struct = Hash.new
			if storage["no_device"]
				vol_struct[:no_device] = storage["no_device"]
			end

			if storage["device"]
				vol_struct[:device_name] = storage["device"]
			elsif storage["no_device"].nil?
				vol_struct[:device_name] = @disk_devices.shift
			end

			vol_struct[:virtual_name] = storage["virtual_name"] if storage["virtual_name"]

			if storage["snapshot_id"] or storage["size"]
				vol_struct[:ebs] = Hash.new
				vol_struct[:ebs][:snapshot_id] = storage["snapshot_id"] if storage["snapshot_id"]
				vol_struct[:ebs][:volume_size] = storage["size"] if storage["size"]
				vol_struct[:ebs][:volume_type] = storage["volume_type"] if storage["volume_type"]
				vol_struct[:ebs][:iops] = storage["iops"] if storage["iops"] and storage["volume_type"] == "io1"
				vol_struct[:ebs][:delete_on_termination] = storage["delete_on_termination"]
				vol_struct[:ebs][:encrypted] = storage["encrypted"] if storage["encrypted"]
			end

			return vol_struct
		end

		# Generate a random password which will satisfy the complexity requirements
		# of stock Amazon Windows AMIs.
		# return [String]: A password string.
		def self.generateWindowsAdminPassword
		  # We have dopey complexity requirements, be stringent here. I'll be nice
		  # and not condense this into one elegant-but-unreadable regular expression
		  attempts = Array.new
		  safe_metachars = Regexp.escape('~!@#%^&*_-+=`|(){}[]:;<>,.?')
		  begin
		    if attempts.size > 25
		      puts "Lousy passwords:"
		      puts attempts
		      raise MuError, "Failed to generate an adequate password!"
		    end
		    winpass=Password.random(14..16)
		    attempts << winpass
		  end while winpass.nil? or !winpass.match(/[A-Z]/) or !winpass.match(/[a-z]/) or !winpass.match(/\d/) or !winpass.match(/[#{safe_metachars}]/) or winpass.match(/[^\w\d#{safe_metachars}]/)
			MU.log "Generated Windows admin password #{winpass} after #{attempts} attempts", MU::DEBUG
			return winpass
		end

		@eips_used = Array.new
		# Find a free AWS Elastic IP.
		# @param classic [Boolean]: Toggle whether to allocate an IP in EC2 Classic
		# instead of VPC.
		# @param ip [String]: Request a specific IP address.
		# @param region [String]: The cloud provider region
		def self.findFreeElasticIp(classic = false, ip: ip, region: MU.curRegion)
				filters = Array.new
				filters << { name: "domain", values: ["vpc"] } if !classic
				filters << { name: "public-ip", values: [ip] } if ip != nil

				if filters.size > 0
					resp = MU.ec2(region).describe_addresses(filters: filters)
				else
					resp = MU.ec2(region).describe_addresses()
				end
				resp.addresses.each { |address|
					return address if (address.instance_id.nil? or address.instance_id.empty?) and address.network_interface_id.nil? and !@eips_used.include?(address.public_ip)
				}
				if ip != nil
					if !classic
						raise MuError, "Requested EIP #{ip}, but no such IP exists in VPC domain"
					else
						raise MuError, "Requested EIP #{ip}, but no such IP exists in Classic domain"
					end
				end
				if !classic
					resp = MU.ec2(region).allocate_address(domain: "vpc")
					new_ip = resp.public_ip
				else
					new_ip = MU.ec2(region).allocate_address().public_ip
				end
				filters = [ { name: "public-ip", values: [new_ip] } ]
				if resp.domain
					filters << { name: "domain", values: [resp.domain] }
				end rescue NoMethodError
				if new_ip.nil?
					MU.log "Unable to allocate new Elastic IP. Are we at quota?", MU::ERR
					raise MuError, "Unable to allocate new Elastic IP. Are we at quota?"
				end
				MU.log "Allocated new EIP #{new_ip}, fetching full description"


				begin
					begin
						sleep 5
						resp = MU.ec2(region).describe_addresses(
							filters: filters
						)
						addr = resp.addresses.first
					end while resp.addresses.size < 1 or addr.public_ip.nil?
				rescue NoMethodError
					MU.log "EIP descriptor came back without a public_ip attribute for #{new_ip}, retrying", MU::WARN
					sleep 5
					retry
				end

				return addr
		end

		@eip_semaphore = Mutex.new
		# Associate an Amazon Elastic IP with an instance.
		# @param instance_id [String]: The cloud provider identifier of the instance.
		# @param classic [Boolean]: Whether to assume we're using an IP in EC2 Classic instead of VPC.
		# @param ip [String]: Request a specific IP address.
		# @param region [String]: The cloud provider region
		# @return [void]
		def self.associateElasticIp(instance_id, classic: classic = false, ip: ip, region: MU.curRegion)
			MU.log "associateElasticIp called: #{instance_id}, classic: #{classic}, ip: #{ip}, region: #{region}", MU::DEBUG
			elastic_ip = nil
			@eip_semaphore.synchronize {
				if !ip.nil?
					filters = [ { name: "public-ip", values: [ip] } ]
					resp = MU.ec2(region).describe_addresses(filters: filters)
					if @eips_used.include?(ip)
						is_free = false
						resp.addresses.each { |address|
							if address.public_ip == ip and (address.instance_id.nil? and address.network_interface_id.nil?) or address.instance_id == instance_id
								@eips_used.delete(ip)
								is_free = true
							end
						}
	
						raise MuError, "Requested EIP #{ip}, but we've already assigned this IP to someone else" if !is_free
					else
						resp.addresses.each { |address|
							if address.public_ip == ip and address.instance_id == instance_id
								return ip
							end
						}
					end
				end
				elastic_ip = findFreeElasticIp(classic, ip: ip)
				if !ip.nil? and (elastic_ip.nil? or ip != elastic_ip.public_ip)
					raise MuError, "Requested EIP #{ip}, but this IP does not exist or is not available"
				end
				if elastic_ip.nil?
					raise MuError, "Couldn't find an Elastic IP to associate with #{instance_id}"
				end
				@eips_used << elastic_ip.public_ip
				MU.log "Associating Elastic IP #{elastic_ip.public_ip} with #{instance_id}", details: elastic_ip
			}
			attempts = 0
			begin
				if classic
					resp = MU.ec2(region).associate_address(
						instance_id: instance_id,
						public_ip: elastic_ip.public_ip
					)
				else
					resp = MU.ec2(region).associate_address(
						instance_id: instance_id,
						allocation_id: elastic_ip.allocation_id,
						allow_reassociation: false
					)
				end
			rescue Aws::EC2::Errors::IncorrectInstanceState => e
				attempts = attempts + 1
				if attempts < 6
					MU.log "Got #{e.message} associating #{elastic_ip.allocation_id} with #{instance_id}, retrying", MU::WARN
					sleep 5
					retry
				end
				raise MuError "#{e.message} associating #{elastic_ip.allocation_id} with #{instance_id}"
			rescue Aws::EC2::Errors::ResourceAlreadyAssociated => e
				# A previous association attempt may have succeeded, albeit slowly.
				resp = MU.ec2(region).describe_addresses(
					allocation_ids: [elastic_ip.allocation_id]
				)
				first_addr = resp.addresses.first
				if !first_addr.nil? and first_addr.instance_id == instance_id
					MU.log "#{elastic_ip.public_ip} already associated with #{instance_id}", MU::WARN
				else
					MU.log "#{elastic_ip.public_ip} shows as already associated!", MU::ERR, details: resp
					raise MuError, "#{elastic_ip.public_ip} shows as already associated with #{first_addr.instance_id}!"
				end
			end

			instance = MU.ec2(region).describe_instances(instance_ids: [instance_id]).reservations.first.instances.first
			waited = false
			if instance.public_ip_address != elastic_ip.public_ip
				waited = true
				begin
					sleep 10
					MU.log "Waiting for Elastic IP association of #{elastic_ip.public_ip} to #{instance_id} to take effect", MU::NOTICE
					instance = MU.ec2(region).describe_instances(instance_ids: [instance_id]).reservations.first.instances.first
				end while instance.public_ip_address != elastic_ip.public_ip
			end

			MU.log "Elastic IP #{elastic_ip.public_ip} now associated with #{instance_id}" if waited

			return elastic_ip.public_ip
		end  

		# Remove all instances associated with the currently loaded deployment. Also cleans up associated volumes, droppings in the MU master's /etc/hosts and ~/.ssh, and in Chef.
		# @param noop [Boolean]: If true, will only print what would be done
		# @param ignoremaster [Boolean]: If true, will remove resources not flagged as originating from this Mu server
		# @param region [String]: The cloud provider region
		# @return [void]
		def self.cleanup(noop = false, ignoremaster = false, skipsnapshots: false, onlycloud: false, region: MU.curRegion)
			tagfilters = [
				{ name: "tag:MU-ID", values: [MU.mu_id] }
			]
			if !ignoremaster
				tagfilters << { name: "tag:MU-MASTER-IP", values: [MU.mu_public_ip] }
			end
			instances = Array.new
			unterminated = Array.new

			# Build a list of instances we need to clean up. We guard against
			# accidental deletion here by requiring someone to have hand-terminated
			# these, by default.
			resp = MU.ec2(region).describe_instances(
				filters: tagfilters
			)

			return if resp.data.reservations.nil?
			resp.data.reservations.each { |reservation|
				reservation.instances.each { |instance|
				  if instance.state.name != "terminated"
						unterminated << instance
				  end
				}
			}

			parent_thread_id = Thread.current.object_id

			threads = []
			unterminated.each { |instance|
				threads << Thread.new(instance) { |myinstance|
					MU.dupGlobals(parent_thread_id)
					Thread.abort_on_exception = true
					MU::Server.terminateInstance(id: myinstance.instance_id, noop: noop, onlycloud: onlycloud, region: region)
				}
			}

			resp = MU.ec2(region).describe_volumes(
				filters: tagfilters
			)
			resp.data.volumes.each { |volume|
				threads << Thread.new(volume) { |myvolume|
					MU.dupGlobals(parent_thread_id)
					MU::Server.delete_volume(myvolume, noop, skipsnapshots)
				}
			}

			# Wait for all of the instances to finish cleanup before proceeding
			threads.each { |t|
				t.join
			}


		end

		# Terminate an instance.
		# @param instance [OpenStruct]: The cloud provider's description of the instance.
		# @param id [String]: The cloud provider's identifier for the instance, to use if the full description is not available.
		# @param region [String]: The cloud provider region
		# @return [void]
		def self.terminateInstance(instance = nil, noop: false, id: id, onlycloud: false, region: MU.curRegion)
			ips = Array.new
			if !instance
				if id
					begin
						resp = MU.ec2(region).describe_instances(instance_ids: [id])
					rescue Aws::EC2::Errors::InvalidInstanceIDNotFound => e
						MU.log "Instance #{id} no longer exists", MU::WARN
					end
					if !resp.nil? and !resp.reservations.nil? and !resp.reservations.first.nil?
						instance = resp.reservations.first.instances.first
						ips << instance.public_ip_address if !instance.public_ip_address.nil?
						ips << instance.private_ip_address if !instance.private_ip_address.nil?
					end
				else
					MU.log "You must supply an instance handle or id to terminateInstance", MU::ERR
				end
			else
				id = instance.instance_id
			end
			if !MU.mu_id.empty?
				deploy_dir = File.expand_path("#{MU.dataDir}/deployments/"+MU.mu_id)
				if Dir.exist?(deploy_dir) and !noop
					FileUtils.touch("#{deploy_dir}/.cleanup-"+id)
				end
			end

			cleaned_dns = false
			mu_name = nil
			mu_zone, junk = MU::DNSZone.find(name: "mu")
			if !mu_zone.nil?
				dns_targets = []
				rrsets = MU.route53(region).list_resource_record_sets(hosted_zone_id: mu_zone.id)
			end
			begin
				junk, mu_name = MU::Server.find(id: id, region: region)
			rescue Aws::EC2::Errors::InvalidInstanceIDNotFound => e
				MU.log "Instance #{id} no longer exists", MU::DEBUG
			end

			if !onlycloud and !mu_name.nil?
				if !rrsets.nil?
					rrsets.resource_record_sets.each { |rrset|
						if rrset.name.match(/^#{mu_name.downcase}\.server\.#{MU.myInstanceId}\.mu/i)
							rrset.resource_records.each { |record|
								MU::DNSZone.genericDNSEntry(mu_name, record.value, MU::Server, delete: true)
								cleaned_dns = true
							}
						end
					}
				end

				deploydata = MU::MommaCat.getResourceDeployStruct(MU::Server.cfg_plural, name: mu_name)
				nodename = nil
				deploydata.each_pair { |node, data|
					if data['instance_id'] == id
						nodename = node
						break
					end
				}
				
				orig_config = nil
				sources = []
				if MU.mommacat.original_config.has_key?(MU::Server.cfg_plural)
					sources.concat(MU.mommacat.original_config[MU::Server.cfg_plural])
				end
				if MU.mommacat.original_config.has_key?(MU::ServerPool.cfg_plural)
					sources.concat(MU.mommacat.original_config[MU::ServerPool.cfg_plural])
				end
				sources.each { |svr|
					if svr['name'] == mu_name
						orig_config = svr
						break
					end
				}

				# Expunge the IAM profile for this instance class
				if orig_config["#MU_CLASS"] == "MU::Server"
					MU::Server.removeIAMProfile("Server-"+mu_name) if !noop
				else
					MU::Server.removeIAMProfile("ServerPool-"+mu_name) if !noop
				end

				MU::Server.purgeChefResources(nodename, orig_config['vault_access'], noop)

				MU.mommacat.notify(MU::Server.cfg_plural, mu_name, nodename, remove: true, sub_key: nodename) if !noop and MU.mommacat

				# If we didn't manage to find this instance's Route53 entry by sifting
				# deployment metadata, see if we can get it with the Name tag.
				if !mu_zone.nil? and !cleaned_dns and !instance.nil?
					instance.tags.each { |tag|
						if tag.key == "Name"
							rrsets.resource_record_sets.each { |rrset|
								if rrset.name.match(/^#{tag.value.downcase}\.server\.#{MU.myInstanceId}\.mu/i)
									rrset.resource_records.each { |record|
										MU::DNSZone.genericDNSEntry(tag.value, record.value, MU::Server, delete: true) if !noop
									}
								end
							}
						end
					}
				end
			end

			if ips.size > 0 and !onlycloud
				known_hosts_files = [Etc.getpwuid(Process.uid).dir+"/.ssh/known_hosts"] 
				if Etc.getpwuid(Process.uid).name == "root"
					known_hosts_files << Etc.getpwnam("nagios").dir+"/.ssh/known_hosts"
				end
				known_hosts_files.each { |known_hosts|
					next if !File.exists?(known_hosts)
					MU.log "Cleaning up #{ips} from #{known_hosts}"
					if !noop 
						File.open(known_hosts, File::CREAT|File::RDWR, 0644) { |f|
							f.flock(File::LOCK_EX)
							newlines = Array.new
							f.readlines.each { |line|
								ip_match = false
								ips.each { |ip|
									if line.match(/(^|,| )#{ip}( |,)/)
										MU.log "Expunging #{ip} from #{known_hosts}"
										ip_match = true
									end
								}
								newlines << line if !ip_match
							}
							f.rewind
							f.truncate(0)
							f.puts(newlines)
							f.flush
							f.flock(File::LOCK_UN)
						}
					end
				}
			end


			return if instance.nil?

			name = ""
			instance.tags.each { |tag|
				name = tag.value if tag.key == "Name"
			}

			if instance.state.name == "terminated"
				MU.log "#{instance.instance_id} (#{name}) has already been terminated, skipping"
			else
				if instance.state.name == "terminating"
					MU.log "#{instance.instance_id} (#{name}) already terminating, waiting"
				elsif instance.state.name != "running" and instance.state.name != "pending" and instance.state.name != "stopping" and instance.state.name != "stopped"
					MU.log "#{instance.instance_id} (#{name}) is in state #{instance.state.name}, waiting"
				else
					MU.log "Terminating #{instance.instance_id} (#{name})"
					if !noop
						begin
							MU.ec2(region).modify_instance_attribute(
								instance_id: instance.instance_id,
								disable_api_termination: { value: false }
							)
							MU.ec2(region).terminate_instances(instance_ids: [instance.instance_id])
							# Small race window here with the state changing from under us
						rescue Aws::EC2::Errors::RequestLimitExceeded
							sleep 10
							retry
						rescue Aws::EC2::Errors::IncorrectInstanceState => e
							resp = MU.ec2(region).describe_instances(instance_ids: [id])
							if !resp.nil? and !resp.reservations.nil? and !resp.reservations.first.nil?
								instance = resp.reservations.first.instances.first
								if !instance.nil? and instance.state.name != "terminated" and instance.state.name != "terminating"
									sleep 5
									retry
								end
							end
						rescue Aws::EC2::Errors::InternalError => e
							MU.log "Error #{e.inspect} while Terminating instance #{instance.instance_id} (#{name}), retrying", MU::WARN, details: e.inspect
							sleep 5
							retry
						end
					end
				end
				while instance.state.name != "terminated" and !noop
					sleep 30
					instance_response = MU.ec2(region).describe_instances(instance_ids: [instance.instance_id])
					instance = instance_response.reservations.first.instances.first
				end
				MU.log "#{instance.instance_id} (#{name}) terminated" if !noop
			end
		end

		# Expunge Chef resources associated with a node.
		# @param node [String]: The Mu name of the node in question.
		def self.purgeChefResources(node, vaults_to_clean = [], noop = false)
			MU.log "Deleting Chef resources associated with #{node}"
			vaults_to_clean.each { |vault|
				MU::MommaCat.lock("vault-"+vault['vault'], false, true)
				MU.log "knife vault remove #{vault['vault']} #{vault['item']} --search name:#{node}", MU::NOTICE
				puts `#{MU::Config.knife} vault remove #{vault['vault']} #{vault['item']} --search name:#{node}` if !noop
				MU::MommaCat.unlock("vault-"+vault['vault'])
			}
			MU.log "knife node delete -y #{node}"
			`#{MU::Config.knife} node delete -y #{node}` if !noop
			MU.log "knife client delete -y #{node}"
			`#{MU::Config.knife} client delete -y #{node}` if !noop
			MU.log "knife data bag delete -y #{node}"
			`#{MU::Config.knife} data bag delete -y #{node}` if !noop
			["crt", "key"].each { |ext|
				if File.exists?("#{MU.mySSLDir}/#{node}.#{ext}")
					MU.log "Removing #{MU.mySSLDir}/#{node}.#{ext}"
					File.unlink("#{MU.mySSLDir}/#{node}.#{ext}") if !noop
				end
			}
		end

		private

		# Destroy a volume.
		# @param volume [OpenStruct]: The cloud provider's description of the volume.
		# @param id [String]: The cloud provider's identifier for the volume, to use if the full description is not available.
		# @param region [String]: The cloud provider region
		# @return [void]
		def self.delete_volume(volume, noop, skipsnapshots, id: id, region: MU.curRegion)
			if !volume.nil?
				resp = MU.ec2(region).describe_volumes(volume_ids: [volume.volume_id])
				volume = resp.data.volumes.first
			end
			name = ""
			volume.tags.each { |tag|
				name = tag.value if tag.key == "Name"
			}

			MU.log("Deleting volume #{volume.volume_id} (#{name})")
			if !noop
				if !skipsnapshots
					if !name.nil? and !name.empty?
							desc = "#{MU.mu_id}-MUfinal (#{name})"
					else
							desc = "#{MU.mu_id}-MUfinal"
					end

					MU.ec2(region).create_snapshot(
						volume_id: volume.volume_id,
						description: desc
					)
				end

				retries = 0
				begin
					MU.ec2(region).delete_volume(volume_id: volume.volume_id)
				rescue Aws::EC2::Errors::RequestLimitExceeded
					sleep 10
					retry
				rescue Aws::EC2::Errors::InvalidVolumeNotFound
					MU.log "Volume #{volume.volume_id} (#{name}) disappeared before I could remove it!", MU::WARN
				rescue Aws::EC2::Errors::VolumeInUse
					if retries < 10
						volume.attachments.each { |attachment|
							MU.log "#{volume.volume_id} is attached to #{attachment.instance_id} as #{attachment.device}", MU::NOTICE
						}
						MU.log "Volume '#{name}' is still attached, waiting...", MU::NOTICE
						sleep 30
						retries = retries + 1
						retry
					else
						MU.log "Failed to delete #{name}", MU::ERR
					end
				end
			end
		end


		def self.runChef(nodename, server, keyname, purpose = "Chef run", max_retries = 5)
			nat_ssh_key, nat_ssh_user, nat_ssh_host = MU::Server.getNodeSSHProxy(server)
			MU.log "Invoking Chef on #{nodename}: #{purpose}"
			retries = 0
			output = []
			error_signal = "CHEF EXITED BADLY: "+(0...25).map { ('a'..'z').to_a[rand(26)] }.join
			begin
				ssh = MU::Server.getSSHSession(server, keyname)
				cmd = nil
				if server["platform"] != "windows" and
					 server['platform'] != "win2k12" and
					 server['platform'] != "win2k12r2"
					if !server["ssh_user"].nil? and
						 !server["ssh_user"].empty? and
						 server["ssh_user"] != "root"
						cmd = "sudo chef-client --color || echo #{error_signal}"
					else
						cmd = "chef-client --color || echo #{error_signal}"
					end
				else
					cmd = "$HOME/chef-client --color || echo #{error_signal}"
				end
				retval = ssh.exec!(cmd) { |ch, stream, data|
#					if stream == :stderr
					puts data
					output << data
					if data.match(/#{error_signal}/)
						raise ChefRunFail, output.grep(/ ERROR: /).last
					end
				}

		  rescue Net::SSH::HostKeyMismatch => e
		    MU.log("Remembering new key: #{e.fingerprint}")
		    e.remember_host!
				ssh.close
		    retry
		  rescue SystemCallError, Timeout::Error, Errno::EHOSTUNREACH, Net::SSH::Proxy::ConnectError, SocketError, Net::SSH::Disconnect, Net::SSH::AuthenticationFailed, Net::SSH::Disconnect, IOError => e
				ssh.close if !ssh.nil?
				if retries < max_retries
					retries = retries + 1
					MU.log "#{nodename}: #{e.inspect} trying to connect for Chef run '#{purpose}", MU::WARN
					sleep 30
					retry
				else
					MU.log "#{nodename}: #{e.inspect} trying to connect for Chef run '#{purpose}", MU::ERR
					raise MuError, "#{nodename}: #{e.inspect} trying to connect for Chef run '#{purpose}"
				end
		  rescue ChefRunFail => e
				ssh.close if !ssh.nil?
				if retries < max_retries
					retries = retries + 1
					MU.log "#{nodename}: Chef run '#{purpose}' failed, retrying", MU::WARN, details: e.message
					sleep 10
					retry
				else
					MU.log "#{nodename}: Chef run '#{purpose}' failed #{max_retries} times", MU::ERR, details: e.message
					raise e
				end
			end
		end

		# @param server [Hash]:
		# @param node_ssh_key [String]:
		# @return [Net::SSH::Connection::Session]
		def self.getSSHSession(server, node_ssh_key, loglevel = MU::NOTICE)
			ssh_keydir = Etc.getpwuid(Process.uid).dir+"/.ssh"
			nat_ssh_key, nat_ssh_user, nat_ssh_host = MU::Server.getNodeSSHProxy(server)
			session = nil
			begin
				if !nat_ssh_host.nil? and !MU::VPC.haveRouteToInstance?(server['instance_id'])
					proxy_cmd = "ssh -q -o StrictHostKeyChecking=no -W %h:%p #{nat_ssh_user}@#{nat_ssh_host}"
					MU.log "Attempting SSH to #{node} (#{server['canonical_ip']}) as #{server['ssh_user']} with key #{node_ssh_key} using proxy '#{proxy_cmd}'", loglevel
						proxy = Net::SSH::Proxy::Command.new(proxy_cmd)
						session = Net::SSH.start(
								server['canonical_ip'],
								server['ssh_user'],
								:config => false, 
								:keys_only => true,
								:keys => [ssh_keydir+"/"+nat_ssh_key, ssh_keydir+"/"+node_ssh_key],
								:paranoid => false,
	#							:verbose => :info,
								:port => 22,
								:auth_methods => ['publickey'],
								:proxy => proxy
							)
				else
					MU.log "Attempting SSH to #{server['canonical_ip']} as #{server['ssh_user']} with key #{ssh_keydir}/#{node_ssh_key}", loglevel
						session = Net::SSH.start(
							server['canonical_ip'],
							server['ssh_user'],
							:config => false, 
							:keys_only => true,
							:keys => [ssh_keydir+"/"+node_ssh_key],
							:paranoid => false,
	#						:verbose => :info,
							:port => 22,
							:auth_methods => ['publickey']
						)
		    end
			  rescue Net::SSH::HostKeyMismatch => e
			    MU.log("Remembering new key: #{e.fingerprint}")
			    e.remember_host!
			    retry
				end
			return session
		end

		# Add a role or recipe to a node. Optionally, throw a fit if it doesn't exist.
		# @param node [String]: The node (Chef name) of the node to modify.
		# @param rl_entry [String]: The run-list entry to add.
		# @param type [String]: One of *role* or *recipe*.
		# @param ignore_missing [Boolean]: If set to true, will merely warn about missing recipes/roles instead of throwing an exception.
		# @return [void]
		def self.knifeAddToRunList(node, rl_entry, type="role", ignore_missing=false)
		  return if rl_entry.nil?
		
		  # Rather than argue about whether to expect a bare rl_entry name or require
		  # rl_entry[rolename], let's just accomodate.
		  if rl_entry.match(/^role\[(.+?)\]/) then
			  type = "role"
		    rl_entry = Regexp.last_match(1)
		    query=%Q{#{MU::Config.knife} role show #{rl_entry}};
		  elsif rl_entry.match(/^recipe\[(.+?)\]/) then
			  type = "recipe"
		    rl_entry = Regexp.last_match(1)
		    query=%Q{#{MU::Config.knife} recipe list | grep '^#{rl_entry}$'};
		  end
		
			%x{#{query}}
		  if $? != 0 then
		    raise MuError, "Attempted to add non-existing #{type} #{rl_entry}" if !ignore_missing
		  end
		
		
		  begin
		    query=%Q{#{MU::Config.knife} node run_list add #{node} "#{type}[#{rl_entry}]"};
				MU.log("Adding #{type} #{rl_entry} to #{node}")
				MU.log("Running #{query}", MU::DEBUG)
		    output=%x{#{query}}
		# XXX rescue Exception is bad style
		  rescue Exception => e
		    raise MuError, "FAIL: #{MU::Config.knife} node run_list add #{node} \"#{type}[#{rl_entry}]\": #{e.message} (output was #{output})"
		  end
		end

	end #class
end #module
