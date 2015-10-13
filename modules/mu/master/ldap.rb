#!/usr/local/ruby-current/bin/ruby
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

require 'net-ldap'

module MU
  class Master
    class LDAP
      require 'date'

      @ldap_conn = nil
      # Create and return a connection to our directory service. If we've
      # already opened one, return that.
      # @return [Net::LDAP]
      def self.getLDAPConnection
        return @ldap_conn if @ldap_conn
        bind_creds = MU::Groomer::Chef.getSecret(vault: $MU_CFG["ldap"]["svc_acct_vault"], item: $MU_CFG["ldap"]["svc_acct_item"])
        @ldap_conn = Net::LDAP.new(
          :host => $MU_CFG["ldap"]["dcs"].first,
          :encryption => :simple_tls,
          :port => 636,
          :base => $MU_CFG["ldap"]["base_dn"],
          :auth => {
            :method => :simple,
            :username => bind_creds["dn"],
            :password => bind_creds["password"]
          }
        )
        @ldap_conn
      end

      # Shorthand for fetching the most recent error on the active LDAP
      # connection
      def self.getLDAPErr
        return nil if !@ldap_conn
        return @ldap_conn.get_operation_result.code.to_s+" "+@ldap_conn.get_operation_result.message.to_s
      end

      # Approximate a current Microsoft timestamp. They count the number of
      # 100-nanoseconds intervals (1 nanosecond = one billionth of a second)
      # since Jan 1, 1601 UTC.
      def self.getMicrosoftTime
        ms_epoch = DateTime.new(1601,1,1)
        # this is in milliseconds, so multiply it for the right number of zeroes
        elapsed = DateTime.now.strftime("%Q").to_i - ms_epoch.strftime("%Q").to_i
        return elapsed*10000
      end

      # Convert a Microsoft timestamp to a Ruby Time object. See also #getMicrosoftTime.
      # @param stamp [Integer]: The MS-style timestamp, e.g. 130838184558490696
      # @return [Time]
      def self.convertMicrosoftTime(stamp)
        ms_epoch = DateTime.new(1601,1,1).strftime("%Q").to_i
        unixtime = (stamp.to_i/10000) + DateTime.new(1601,1,1).strftime("%Q").to_i
        Time.at(unixtime/1000)
      end

      @can_write = nil
      # Test whether our LDAP binding user has permissions to create other
      # users, manipulate groups, and set passwords. Note that it's *not* fatal
      # if we can't, simply a design where most account management happens on
      # the directory side.
      # @return [Boolean]
      def self.canWriteLDAP?
        return @can_write if !@can_write.nil?

        conn = getLDAPConnection
        dn = "CN=Mu Testuser #{Process.pid},#{$MU_CFG["ldap"]["base_dn"]}"
        attr = {
          :cn => "Mu Testuser #{Process.pid}",
          :objectclass => ["user"],
          :samaccountname => "mu.testuser.#{Process.pid}",
          :userPrincipalName => "mu.testuser.#{Process.pid}@#{$MU_CFG["ldap"]["domain_name"]}",
          :pwdLastSet => "-1"
        }

        @can_write = true
        if !conn.add(:dn => dn, :attributes => attr)
          MU.log "Couldn't create write-test user #{dn}, operating in read-only LDAP mode", MU::NOTICE, details: getLDAPErr
          return false
        end

        # Make sure we can write various fields that we might need to touch
        [:displayName, :mail, :givenName, :sn].each { |field|
          if !conn.replace_attribute(dn, field, "foo@bar.com")
            MU.log "Couldn't modify write-test user #{dn} field #{field.to_s}, operating in read-only LDAP mode", MU::NOTICE, details: getLDAPErr
            @can_write = false
            break
          end
        }

        # Can we add them to the Mu membership group(s)
        if !conn.modify(:dn => $MU_CFG["ldap"]["admin_group_dn"], :operations => [[:add, :member, dn]])
          MU.log "Couldn't add write-test user #{dn} to group #{$MU_CFG["ldap"]["admin_group_dn"]}, operating in read-only LDAP mode", MU::NOTICE, details: getLDAPErr
          @can_write = false
        end

        if !conn.delete(:dn => dn)
          MU.log "Couldn't delete write-test user #{dn}, operating in read-only LDAP mode", MU::NOTICE
          @can_write = false
        end

        @can_write
      end

      # Search for groups whose names contain any of the given search terms and
      # return their full DNs.
      # @param search [Array<String>]: Strings to search for.
      # @param exact [Boolean]: Return only exact matches for whole fields.
      # @param searchbase [String]: The DN under which to search.
      # @return [Array<String>]
      def self.findGroups(search = [], exact: false, searchbase: $MU_CFG['ldap']['base_dn'])
        if search.nil? or search.size == 0
          raise MuError, "Need something to search for in MU::Master::LDAP.findGroups"
        end
        conn = getLDAPConnection
        filter = nil
        search.each { |term|
          curfilter = Net::LDAP::Filter.contains("sAMAccountName", "#{term}")
          if exact
            curfilter = Net::LDAP::Filter.eq("sAMAccountName", "#{term}")
          end

          if !filter
            filter = curfilter
          else
            filter = filter | curfilter
          end
        }
        filter = Net::LDAP::Filter.ne("objectclass", "computer") & (filter)
        groups = []
        conn.search(
          :filter => filter,
          :base => searchbase,
          :attributes => ["objectclass"]
        ) do |group|
          groups << group.dn
        end
        groups
      end

      # See https://technet.microsoft.com/en-us/library/ee198831.aspx
      AD_PW_ATTRS = {
        'noPwdRequired' => 0x0020, #ADS_UF_PASSWD_NOTREQD
        'cantChangePwd' => 0x0040, #ADS_UF_PASSWD_CANT_CHANGE
        'pwdStoredReversible' => 0x0080, #ADS_UF_ENCRYPTED_TEXT_PASSWORD_ALLOWED
        'pwdNeverExpires' => 0x10000, #ADS_UF_DONT_EXPIRE_PASSWD
        'pwdExpired' => 0x80000 #ADS_UF_PASSWORD_EXPIRED
      }.freeze

      # Find a directory user with fuzzy string matching on sAMAccountName, displayName, group memberships, or email
      # @param search [Array<String>]: Strings to search for.
      # @param exact [Boolean]: Return only exact matches for whole fields.
      # @param searchbase [String]: The DN under which to search.
      # @return [Array<Hash>]
      def self.findUsers(search = [], exact: false, searchbase: $MU_CFG['ldap']['base_dn'], extra_attrs: [])
        # We want to search groups, but can't search on memberOf with wildcards.
        # So search groups independently, build a list of full CNs, and use
        # those.
        if search.size > 0
          groups = findGroups(search, exact: exact, searchbase: searchbase)
        end
        searchattrs = ["sAMAccountName", "displayName", "mail"] + extra_attrs
        getattrs = searchattrs + ["lastLogon", "lockoutTime", "pwdLastSet", "memberOf", "userAccountControl"]
        conn = getLDAPConnection
        users = {}
        filter = nil
        rejected = 0
        if search.size > 0
          search.each { |term|
            if term.length < 4 and !exact
              MU.log "Search term '#{term}' is too short, ignoring.", MU::WARN
              rejected = rejected + 1
              next
            end
            searchattrs.each { |attr|
              if !filter
                if exact
                  filter = Net::LDAP::Filter.eq(attr, "#{term}")
                else
                  filter = Net::LDAP::Filter.contains(attr, "#{term}")
                end
              else
                if exact
                  filter = filter |Net::LDAP::Filter.eq(attr, "#{term}")
                else
                  filter = filter |Net::LDAP::Filter.contains(attr, "#{term}")
                end
              end
            }
          }
          if rejected == search.size
            MU.log "No valid search strings provided.", MU::ERR
            return nil
          end
        end
        if groups
          groups.each { |group|
            filter = filter |Net::LDAP::Filter.eq("memberOf", group)
          }
        end
        if filter 
          filter = Net::LDAP::Filter.ne("objectclass", "computer") & Net::LDAP::Filter.ne("objectclass", "group") & (filter)
        else
          filter = Net::LDAP::Filter.ne("objectclass", "computer") & Net::LDAP::Filter.ne("objectclass", "group")
        end
        conn.search(
          :filter => filter,
          :base => searchbase,
          :attributes => getattrs
        ) do |acct|
          begin
            next if users.has_key?(acct.samaccountname.first)
          rescue NoMethodError
            next
          end
          users[acct.samaccountname.first] = {}
          users[acct.samaccountname.first]['dn'] = acct.dn
          getattrs.each { |attr|
            begin
              if acct[attr].size == 1
                users[acct.samaccountname.first][attr] = acct[attr].first
              else
                users[acct.samaccountname.first][attr] = acct[attr]
              end
              if attr == "userAccountControl"
                AD_PW_ATTRS.each_pair { |pw_attr, bitmask|
                  if (bitmask | acct[attr].first.to_i) == acct[attr].first.to_i
                    users[acct.samaccountname.first][pw_attr] = true
                  end
                }
                users[acct.samaccountname.first][attr] = acct[attr].first.to_i.to_s(2)
              end
            end rescue NoMethodError
          }
        end
        users
      end

      # @return [Array<String>]
      def self.listUsers
        conn = getLDAPConnection
        users = {}

        ["admin_group_name", "user_group_name"].each { |group|
          groupname_filter = Net::LDAP::Filter.eq("sAMAccountName", $MU_CFG["ldap"][group])
          group_filter = Net::LDAP::Filter.eq("objectClass", "group")
          member_cns = []
          conn.search(
            :filter => Net::LDAP::Filter.join(groupname_filter, group_filter),
            :attributes => ["member"]
          ) do |item|
            member_cns = item.member.dup
          end
          member_cns.each { |member|
            cn = member.dup.sub(/^CN=([^\,]+?),.*/i, "\\1")
            searchbase = member.dup.sub(/^CN=[^\,]+?,(.*)/i, "\\1")
            conn.search(
              :filter => Net::LDAP::Filter.eq("cn",cn),
              :base => searchbase,
              :attributes => ["sAMAccountName", "displayName", "mail"]
            ) do |acct|
              next if users.has_key?(acct.samaccountname.first)
              users[acct.samaccountname.first] = {}
              users[acct.samaccountname.first]['dn'] = acct.dn
              if group == "admin_group_name"
                users[acct.samaccountname.first]['admin'] = true
              else
                users[acct.samaccountname.first]['admin'] = false
              end
              begin
                users[acct.samaccountname.first]['realname'] = acct.displayname.first
              end rescue NoMethodError
              begin
                users[acct.samaccountname.first]['email'] = acct.mail.first
              end rescue NoMethodError
            end
          }
        }
        users
      end

      def self.deleteUser(user)
        cur_users = listUsers

        if cur_users.has_key?(user)
          # Creating a new user
          if canWriteLDAP?
            conn = getLDAPConnection
            dn = nil
            conn.search(
              :filter => Net::LDAP::Filter.eq("sAMAccountName",user),
              :base => $MU_CFG["ldap"]["base_dn"],
              :attributes => ["sAMAccountName"]
            ) do |acct|
              dn = acct.dn
              break
            end
            return false if dn.nil?
            if !conn.delete(:dn => dn)
              MU.log "Failed to delete #{user} from LDAP: #{getLDAPErr}", MU::WARN, details: dn
              return false
            end
            MU.log "Removed LDAP user #{user}", MU::NOTICE
            return true
          else
            MU.log "We are in read-only LDAP mode. You must manually delete #{user} from your directory.", MU::WARN
          end
        else
          MU.log "#{user} does not exist in directory, cannot remove.", MU::DEBUG
          return false
        end
        false
      end

      # Call when creating or modifying a user.
      # @param user [String]: The username on which to operate
      # @param admin [Boolean]: Whether to flag this user as an admin
      def self.manageUser(user, name: nil, password: nil, email: nil, admin: false)
        cur_users = listUsers

        first = last = nil
        if !name.nil?
          last = name.split(/\s+/).pop
          first = name.split(/\s+/).shift
        end
        admin_group = $MU_CFG["ldap"]["admin_group_dn"]

        if !cur_users.has_key?(user)
          # Creating a new user
          if canWriteLDAP?
            if password.nil? or email.nil? or name.nil?
              raise MU::MuError, "Missing one or more required fields (name, password, email) creating new user #{user}"
            end
            user_dn = "CN=#{name},#{$MU_CFG["ldap"]["base_dn"]}"
            conn = getLDAPConnection
            attr = {
              :cn => name,
              :displayName => name,
              :objectclass => ["user"],
              :samaccountname => user,
              :givenName => first,
              :sn => last,
              :mail => email,
              :userPassword => password,
              :userPrincipalName => "#{user}@#{$MU_CFG["ldap"]["domain_name"]}",
              :pwdLastSet => "-1"
            }
            if !conn.add(:dn => user_dn, :attributes => attr)
              raise MU::MuError, "Failed to create user #{user} (#{getLDAPErr})"
            end
            attr[:userPassword] = "********"
            MU.log "Created new LDAP user #{user}", details: attr
            groups = [$MU_CFG["ldap"]["user_group_dn"]]
            groups << admin_group if admin
            groups.each { |group|
              if !conn.modify(:dn => group, :operations => [[:add, :member, user_dn]])
                MU.log "Couldn't add new user #{user} to group #{group}. Access to services may be hampered.", MU::WARN, details: getLDAPErr
              end
            }

            # We now require the system to know that the user exists. Sometimes
            # winbind takes a minute to catch on.
            wait = 5
            begin
              %x{/usr/bin/getent passwd}
              Etc.getpwnam(user)
            rescue ArgumentError
              MU.log "User #{user} has been created in LDAP, but not yet visible to local system, waiting #{wait}s and checking again.", MU::WARN
              sleep wait
              wait = wait + 5
              retry
            end
            MU::Master.setLocalDataPerms(user)
          else
            MU.log "We are in read-only LDAP mode. You must create #{user} in your directory and add it to #{$MU_CFG["ldap"]["user_group_dn"]}. If the user is intended to be an admin, also add it to #{admin_group}.", MU::WARN
            return true
          end
        else
          MU::Master.setLocalDataPerms(user)
          # Modifying an existing user
          if canWriteLDAP?
            conn = getLDAPConnection
            user_dn = cur_users[user]['dn']
            if !name.nil? and cur_users[user]['realname'] != name
              MU.log "Updating display name for #{user} to #{name}", MU::NOTICE
              conn.replace_attribute(user_dn, :displayName, name)
              conn.replace_attribute(user_dn, :givenName, first)
              conn.replace_attribute(user_dn, :sn, last)
              cur_users[user]['realname'] = name
            end
            if !email.nil? and cur_users[user]['email'] != email
              MU.log "Updating email for #{user} to #{email}", MU::NOTICE
              conn.replace_attribute(user_dn, :mail, email)
              cur_users[user]['email'] = email
            end
            if !password.nil?
              MU.log "Updating password for #{user}", MU::NOTICE
              if !conn.replace_attribute(user_dn, :userPassword, password)
                MU.log "Couldn't update password for user #{user}.", MU::WARN, details: getLDAPErr
              end
            end
            if admin and !cur_users[user]['admin']
              MU.log "Granting Mu admin privileges to #{user}", MU::NOTICE
              if !conn.modify(:dn => admin_group, :operations => [[:add, :member, user_dn]])
                MU.log "Couldn't add user #{user} (#{user_dn}) to group #{admin_group}.", MU::WARN, details: getLDAPErr
              end
            elsif !admin and cur_users[user]['admin']
              MU.log "Revoking Mu admin privileges from #{user}", MU::NOTICE
              if !conn.modify(:dn => admin_group, :operations => [[:delete, :member, user_dn]])
                MU.log "Couldn't remove user #{user} (#{user_dn}) from group #{admin_group}.", MU::WARN, details: getLDAPErr
              end
            end
          else
          end
        end
        cur_users = MU::Master.listUsers

        ["realname", "email", "monitoring_email"].each { |field|
          next if !cur_users[user].has_key?(field)
          File.open($MU_CFG['datadir']+"/users/#{user}/#{field}", File::CREAT|File::RDWR, 0640) { |f|
            f.puts cur_users[user][field]
          }
        }
        MU::Master.setLocalDataPerms(user)
        true
      end

    end
  end
end
