#
# Cookbook Name:: mu-master
# Recipe:: update_nagios_bonly
#
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

include_recipe "nagios"
["/usr/lib/cgi-bin/nagios3", "/usr/lib/nagios3", "/etc/nagios", "/etc/nagios3", "/var/log/nagios", "/var/www/html/docs"].each { |dir|
	if Dir.exist?(dir)
		execute "chcon -R -h -t httpd_sys_content_t #{dir}" do
			not_if "ls -aZ #{dir} | grep ':httpd_sys_content_t:'"
			returns [0,1]
			notifies :reload, "service[apache2]", :delayed
		end
	end
}

["/usr/lib/cgi-bin/nagios3", "/usr/lib/cgi-bin"].each { |cgidir|
	if Dir.exist?(cgidir)
		execute "chcon -R -h -t httpd_sys_script_exec_t #{cgidir}" do
			not_if "ls -aZ #{cgidir} | grep ':httpd_sys_script_exec_t:'"
			notifies :reload, "service[apache2]", :delayed
		end
	end
}
execute "chcon -R -h -t nagios_unconfined_plugin_exec_t /usr/lib64/nagios/plugins/check_nagios" do
	not_if "ls -aZ /usr/lib64/nagios/plugins/check_nagios | grep ':nagios_unconfined_plugin_exec_t:'"
end

execute "chgrp apache /var/log/nagios"