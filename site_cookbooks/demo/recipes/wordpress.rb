#
# Cookbook Name:: demo
# Recipe:: wp-cli
#
# Copyright 2015, YOUR_COMPANY_NAME
#
# All rights reserved - Do Not Redistribute
#

include_recipe "php"
include_recipe "apache2"
include_recipe "demo::mysql"
include_recipe "demo::wp-cli"
include_recipe "demo::apache"
include_recipe "demo::iptables-port"



$database=node['deployment']['databases']
$loadbalancer=node['deployment']['loadbalancers']
$lb_url=$loadbalancer['wordpress-demo-lb']['dns'].downcase
$db_name="wordpress_db"
$db_host=$database['wordpress-demo-db']['endpoint']
$db_user=$database['wordpress-demo-db']['username']
$db_password=$database['wordpress-demo-db']['password']
$loadbalancer=node['deployment']['loadbalancers']
$app_url=$loadbalancer['wordpress-demo-lb']['dns'].downcase
$title="mu wordpress demo"
$admin_user="admin"
$admin_password="admin"
$admin_email="admin@example.com"



case node[:platform_family]


when "rhel"	

	execute "yum -y install php-mbstring" do
	 action :run
	end

	execute "yum -y install php-mysql" do
	 action :run
	end

	execute "setsebool httpd_can_network_connect=1" do
	 action :run
	end


	execute "setsebool httpd_can_network_connect=1 | echo SELinux is disabled" do
	 action :run
	end


	bash "Create mysql database in RDS" do
		user "root"
		code <<-EOH
			mysql -h #{$db_host} -u #{$db_user} -p#{$db_password} -e "CREATE DATABASE IF NOT EXISTS #{$db_name};"
		EOH
	end

    
	template '/etc/profile.d/wordpress.sh' do
	    owner 'root'
	    group 'root'
	    mode '0644'
	    source "apache/wordpress.sh.erb"
	    variables({
	              :db_name => $db_name,
	              :db_host => $db_host,
	              :db_user => $db_user,
	              :db_password => $db_password,
	              :domain => $app_url
	            })
	end


	bash "Launch Wordpress site" do
		user "root"
		code <<-EOH
			cd /var/www
			mkdir -p wordpressapp
			cd wordpressapp
			wp core download
			wp core config --dbname=#{$db_name} --dbuser=#{$db_user} --dbpass=#{$db_password} --dbhost=#{$db_host}
			wp core multisite-install --url=#{$app_url} --title='#{$title}' --admin_user=#{$admin_user}  --admin_password=#{$admin_password}  --admin_email=#{$admin_email}

            sed -i "/DB_HOST/s/'[^']*'/getenv('db_host')/2" wp-config.php
		    sed -i "/DB_NAME/s/'[^']*'/getenv('db_name')/2" wp-config.php
		    sed -i "/DB_USER/s/'[^']*'/getenv('db_user')/2" wp-config.php
		    sed -i "/DB_PASSWORD/s/'[^']*'/getenv('db_password')/2" wp-config.php
		    sed -i "/DOMAIN_CURRENT_SITE/s/'[^']*'/getenv('domain')/2" wp-config.php

		EOH
		not_if  {::File.exists?("/var/www/wordpressapp/wp-config.php") }
	end


    template '/var/www/wordpressapp/heartbeat.php' do
    owner 'root'
    group 'root'
    mode '0644'
    source "wordpress/heartbeat.php.erb"
    end


    template '/var/www/wordpressapp/.htaccess' do
    owner 'root'
    group 'root'
    mode '0644'
    source "wordpress/htaccess.erb"
    end



	service "httpd" do
	  action :restart
	end

when "debian"

	

	bash "Create mysql database in RDS" do
		user "root"
		code <<-EOH
			mysql -h #{$db_host} -u #{$db_user} -p#{$db_password} -e "CREATE DATABASE IF NOT EXISTS #{$db_name};"
		EOH
	end


	bash "Launch Wordpress site" do
		user "root"
		code <<-EOH
			cd /var/www
			mkdir -p wordpressapp
			cd wordpressapp
			wp core download
			wp core config --dbname=#{$db_name} --dbuser=#{$db_user} --dbpass=#{$db_password} --dbhost=#{$db_host}
			wp core multisite-install --url=#{$app_url} --title=#{$title} --admin_user=#{$admin_user}  --admin_password=#{$admin_password}  --admin_email=#{$admin_email}
		EOH
		not_if  {::File.exists?("/var/www/wordpressapp/wp-config.php") }
	end



	service "apache2" do
	  action :restart
	end


else

 raise '#{node[:platform_family]} not supported'

end 
