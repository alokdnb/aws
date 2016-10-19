#
# Copyright:: Copyright (c) 2009-2015 Chef Software, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require File.join(File.dirname(__FILE__), 'aws')
require 'open-uri'

module Opscode
  module Aws
    module Ec2
      include Opscode::Aws

      def ec2
        require_aws_sdk

        Chef::Log.debug('Initializing the EC2 Client')
        @ec2 ||= create_aws_interface(::Aws::EC2::Client)
      end

      def instance_id
        node['ec2']['instance_id']
      end

      def instance_availability_zone
        node['ec2']['placement_availability_zone']
      end
      
      def freeze_fs(mount_point)
        system("/sbin/fsfreeze -f #{mount_point}")
      end

      def unfreeze_fs(mount_point)
        system("/sbin/fsfreeze -u #{mount_point}")
      end
      
      # Returns nil or mount point of device
      def discover_mount_point(device)
        ::File.open("/proc/mounts").lines.select{|x| x.start_with?(device + " ")}.map{|x| x.split[1]}.first
      end      
            
      def find_snapshot_id(filters={}, find_most_recent=false, options = {})
        response = ec2.describe_snapshots(
          filters: [
            { name: 'volume-id', values: [volume_id] },
            { name: 'status', values: ['completed'] }
          ]
        )
        snapshots = if find_most_recent
                      # bring the latest snapshot to the front
                      response.snapshots(:filters => filters).sort { |a, b| b[:start_time] <=> a[:start_time] }
                    else
                      response.snapshots(:filters => filters).sort { |a, b| a[:start_time] <=> b[:start_time] }
                    end
        
                    if options.has_key?(:timestamp) && options[:timestamp].kind_of?(Integer) && options[:timestamp] > 0
                      require 'date'
                      dd = DateTime.strptime(options[:timestamp].to_s, "%s")
                      Chef::Log.debug "[find_snapshot_id] select snapshots that were done before #{dd.to_s}"
                      snapshots.select!{ |x|
                        r = DateTime.strptime(x[:aws_started_at], "%FT%T.000Z") < dd
                        Chef::Log.debug "#{x[:aws_id]} -- #{x[:aws_started_at]} -- #{r}"
                        r
                      }
                    end

        # No change just comment for tracking. 
        raise 'Cannot find snapshot id!' if snapshots.empty?
        snapshot_id = snapshots.last[:aws_id] unless snapshots.count == 0
        
        Chef::Log.debug("Snapshot ID is #{snapshots.first[:snapshot_id]}")
        snapshot_id
      end
  
      def sizefs(device)
           block_size, block_count = IO.popen("/sbin/tune2fs -l #{device}") {|x|
             r = x.read
             [r.match(/Block size:[ ]+([0-9]+)/)[1].to_i, r.match(/Block count:[ ]+([0-9]+)/)[1].to_i]
           }
           block_count * block_size
      end

      def device_capability(device)
        IO.popen("/sbin/fdisk -l #{device}") {|x|
          x.read.match(/Disk #{device}:.*, ([0-9]+) bytes/)[1].to_i
        }
      end

      def resize2fs(device)
        if device_capability(device) == (cs = sizefs(device))
          Chef::Log.info "Resize FS action is not needed. We have #{cs} bytes"
        return
        end

        ["/sbin/e2fsck -f -y #{device} 2>&1", "/sbin/resize2fs #{device} 2>&1"].each {|cmd|
          r = IO.popen(cmd) {|x| x.read }
          unless $?.success?
            Chef::Log.error "Fail to perform #{cmd}.\n#{r}"
            break
          end
      }

           Chef::Log.info "#{device} has been resized from #{cs} to #{sizefs(device)} bytes."
         end


      # determine the AWS region of the node
      # Priority: resource property, user set node attribute -> ohai data -> us-east-1
      def aws_region
        # facilitate support for region in resource name
        if new_resource.region
          Chef::Log.debug("Using overridden region name, #{new_resource.region}, from resource")
          new_resource.region
        elsif node.attribute?('ec2')
          Chef::Log.debug("Using region #{instance_availability_zone.chop} from Ohai attributes")
          instance_availability_zone.chop
        else
          Chef::Log.debug('Falling back to region us-east-1 as Ohai data and resource defined region not present')
          'us-east-1'
        end
      end

      private

      # setup AWS instance using passed creds, iam profile, or assumed role
      def create_aws_interface(aws_interface)
        aws_interface_opts = { region: aws_region }

        if !new_resource.aws_access_key.to_s.empty? && !new_resource.aws_secret_access_key.to_s.empty?
          Chef::Log.debug('Using resource-defined credentials')
          aws_interface_opts[:credentials] = ::Aws::Credentials.new(
            new_resource.aws_access_key,
            new_resource.aws_secret_access_key,
            new_resource.aws_session_token)
        else
          Chef::Log.debug('Using local credential chain')
        end

        if !new_resource.aws_assume_role_arn.to_s.empty? && !new_resource.aws_role_session_name.to_s.empty?
          Chef::Log.debug("Assuming role #{new_resource.aws_assume_role_arn}")
          sts_client = ::Aws::STS::Client.new(region: aws_region,
                                              access_key_id: new_resource.aws_access_key,
                                              secret_access_key: new_resource.aws_secret_access_key)
          creds = ::Aws::AssumeRoleCredentials.new(client: sts_client, role_arn: new_resource.aws_assume_role_arn, role_session_name: new_resource.aws_role_session_name)
          aws_interface_opts[:credentials] = creds
        end
        aws_interface.new(aws_interface_opts)
      end

      # fetch the mac address of an interface.
      def query_mac_address(interface)
        node['network']['interfaces'][interface]['addresses'].select do |_, e|
          e['family'] == 'lladdr'
        end.keys.first.downcase
      end

      # fetch the private IP address of an interface from the metadata endpoint.
      def query_default_interface
        Chef::Log.debug("Default instance ID is #{node['network']['default_interface']}")
        node['network']['default_interface']
      end

      def query_private_ip_addresses(interface)
        mac = query_mac_address(interface)
        ip_addresses = open("http://169.254.169.254/latest/meta-data/network/interfaces/macs/#{mac}/local-ipv4s", options = { proxy: false }) { |f| f.read.split("\n") }
        Chef::Log.debug("#{interface} assigned local ipv4s addresses is/are #{ip_addresses.join(',')}")
        ip_addresses
      end

      # fetch the network interface ID of an interface from the metadata endpoint
      def query_network_interface_id(interface)
        mac = query_mac_address(interface)
        eni_id = open("http://169.254.169.254/latest/meta-data/network/interfaces/macs/#{mac}/interface-id", options = { proxy: false }, &:gets)
        Chef::Log.debug("#{interface} eni id is #{eni_id}")
        eni_id
      end
    end
  end
end
