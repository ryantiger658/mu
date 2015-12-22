#!/usr/local/ruby-current/bin/ruby

module Mu
  class Install
    def self.centos_version
      os_version = `rpm -qa \*-release | grep -Ei "redhat|centos" | cut -d"-" -f3`
      puts "This is CentOS #{os_version}"
      process = `ps aux | grep install`
      puts process
    end
  end
end

Mu::Install.centos_version
