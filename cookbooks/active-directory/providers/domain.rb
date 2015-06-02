#
# Cookbook Name:: active-directory
# Provider:: domain
#
# Copyright 2015, eGlobalTech,
#
# All rights reserved - Do Not Redistribute
#

def whyrun_supported?
	true
end

action :create do
	install_ad_features
	elevate_remote_access
	set_computer_name(admin_creds)
	configure_network_interface
	create_domain
	configure_domain
end

action :delete do
	delete_domain
end

# def load_current_resource
	# @current_resource = @new_resource.dup
# end

case node.platform
when "windows"
	include Chef::Mixin::PowershellOut

	def create_domain_admin_user
		unless domain_admin_user_exist?
			code =<<-EOH
				New-ADUser -Name #{new_resource.domain_admin_user} -UserPrincipalName #{new_resource.domain_admin_user}@#{new_resource.dns_name} -AccountPassword (convertto-securestring '#{new_resource.domain_admin_password}' -asplaintext -force) -Enabled $true -PasswordNeverExpires $true
				Add-ADGroupMember 'Domain Admins' -Members #{new_resource.domain_admin_user}
			EOH
			cmd = powershell_out(code).run_command
			Chef::Log.info("Create Domain Admin User #{new_resource.domain_admin_user}")
			# inspect_exit_status(cmd, "Create Domain Admin User #{new_resource.domain_admin_user}")
		end
	end

	#This will restart the OS. The OS needs to be restated after creating the domain
	def create_domain
		unless domain_exists?
			require 'chef/win32/version'
			version = Chef::ReservedNames::Win32::Version.new
			
			if version.windows_server_2012?
				code =<<-EOH
					$DCPromoFile = @"
					[DCINSTALL]
					InstallDNS=yes
					NewDomain=forest
					NewDomainDNSName=#{new_resource.dns_name}
					DomainNetBiosName=#{new_resource.netbios_name}
					SiteName=#{new_resource.site_name}
					ReplicaorNewDomain=domain
					ForestLevel=5
					DomainLevel=5
					ConfirmGC=Yes
					SafeModeAdminPassword="#{new_resource.restore_mode_password}"
					RebootonCompletion=Yes
					"@
					$DCPromoFile | out-file c:/dcpromoanswerfile.txt -Force
					dcpromo.exe /unattend:c:/dcpromoanswerfile.txt
				EOH
				cmd = powershell_out(code).run_command
			elsif version.windows_server_2012_r2?
				cmd = powershell_out("Install-ADDSForest -DomainName #{new_resource.dns_name} -SafeModeAdministratorPassword (convertto-securestring '#{new_resource.restore_mode_password}' -asplaintext -force) -DomainMode Win2012R2 -DomainNetbiosName #{new_resource.netbios_name} -ForestMode Win2012R2 -Confirm:$false -Force").run_command
		
				Chef::Application.fatal!("Failed to create Active Directory Domain #{new_resource.dns_name}") if cmd.exitstatus != 0
				Chef::Application.fatal!("Active Directory Domain #{new_resource.dns_name} was created, rebooting. Will have to run chef again")
			end
		end
	end

	def rename_default_site
		unless default_site_name_set?
			cmd = powershell_out("Get-ADObject -Credential #{admin_creds} -SearchBase (Get-ADRootDSE).ConfigurationNamingContext -filter {Name -eq 'Default-First-Site-Name'} | Rename-ADObject -Credential #{admin_creds} -NewName #{new_resource.site_name}").run_command
			Chef::Log.info("Renamed default site to #{new_resource.site_name}")
			# inspect_exit_status(cmd, "Renamed default site to #{new_resource.site_name}")
		end
	end

	def configure_replication
		new_resource.sites.each { |site|
			if site[:name] != new_resource.site_name
				powershell_script "Creating AD ReplicationSite #{site[:name]}" do
					guard_interpreter :powershell_script
					code "New-ADReplicationSite #{site[:name]} -Credential #{admin_creds}"
					not_if "(Get-ADObject -Credential #{admin_creds} -SearchBase (Get-ADRootDSE).ConfigurationNamingContext -filter {Name -eq '#{site[:name]}'}).name -eq '#{site[:name]}'"
					sensitive true
				end

				powershell_script "Configure AD Replication between AD sites and" do
					guard_interpreter :powershell_script
					code "Get-ADReplicationSiteLink -Credential #{admin_creds} -Filter * | Set-ADReplicationSiteLink -Credential #{admin_creds} -SitesIncluded @{add='#{site[:name]}'} -ReplicationFrequencyInMinutes 15"
					sensitive true
				end
			end

			powershell_script "Create AD Replication subnet #{site[:ip_block]} for site #{site[:name]}" do
				guard_interpreter :powershell_script
				code "New-ADReplicationSubnet -Credential #{admin_creds} -Name #{site[:ip_block]} -Site #{site[:name]}"
				not_if "(Get-ADReplicationSubnet -Credential #{admin_creds} -Identity #{site[:ip_block]}).name -eq '#{site[:ip_block]}'"
				sensitive true
			end
		}
	end

	def configure_domain
		# Move these to somewhere that makes sense
		powershell_out("Set-Service NTDS -StartupType Automatic").run_command
		powershell_out("Set-Service ADWS -StartupType Automatic").run_command

		set_computer_name(admin_creds)
		create_domain_admin_user
		rename_default_site
		configure_replication
		set_replication_static_ports
	end
when "centos", "redhat"
	# To do: Do Active Directory on Linux
else
	Chef::Log.info("Unsupported platform #{node.platform}")
end
