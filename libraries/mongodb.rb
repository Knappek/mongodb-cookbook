#
# Cookbook Name:: mongodb
# Definition:: mongodb
#
# Copyright 2011, edelight GmbH
# Authors:
#       Markus Korn <markus.korn@edelight.de>
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

require 'json'

class Chef::ResourceDefinitionList::MongoDB

  def self.configure_replicaset(node, name, members)
    # lazy require, to move loading this modules to runtime of the cookbook
    require 'rubygems'
    require 'mongo'

    if members.length == 0
      if Chef::Config[:solo]
        abort("Cannot configure replicaset '#{name}', no member nodes found")
      end

      members << node unless members.include?(node)
    end

    host_members = members.collect{ |m| m['fqdn'] + ":" + node['mongodb']['port'].to_s }

    is_replicaset = false

    sleep(10)

    # Connect to existing node, check if replicaset is enabled?! Then proceed
    begin      
      connection = Mongo::ReplSetConnection.new( host_members )
    rescue Mongo::ConnectionFailure => error_code
      if error_code.to_s().include?('Cannot connect to a replica set')
        Chef::Log.warn("Not a replicaset yet")
        is_replicaset = false
      else
        Chef::Log.warn("111 Trying more times. Could not connect to database: 'localhost:#{node['mongodb']['port']}'")
      end
    rescue => error_code
      if error_code.to_s().include?('Cannot connect to a replica set')
        Chef::Log.warn("Not a replicaset yet")
        is_replicaset = false
      else
        Chef::Log.warn("222 Trying more times. Could not connect to database: 'localhost:#{node['mongodb']['port']}'")
      end
    else
      Chef::Log.info("We are a replicaset and we are connected!")
      is_replicaset = true
    end

    # IF we aren't a replica set
    if (is_replicaset == false)
      Chef::Log.info("We are not a replica set ... starting configuring")
      begin
        connection = Mongo::Connection.new([host_members.first])
      rescue => error_Code
        Chef::Log.warn("Unable to connect")
        Chef::Log.warn(error_code)
        return
      end

      ## TODO IMPLEMENT RESCUE AND TRY IF TIMEOUT
      result = connection['admin'].command({:replSetInitiate => 1}, :check_response => false)
      if result.fetch('ok', nil) == 1
        Chef::Log.info('Replicaset has been initiated')
        
        #ALL DONE, WE WILL ADD ANOTHER NODE LATER
        return
      else
        Chef::Log.warn("Replicaset initiation failed with" + result.fetch('errmsg', nil))
      end
    else
      Chef::Log.info("We are a replica set ... ensuring the primary is up and running")
      result = connection['admin'].command({:isMaster => 1}, :check_response => false)
      
      if result.fetch("ok", nil) == 1 and result.fetch("ismaster", nil) == true
        Chef::Log.info("We are connected to the primary, continuing ...")
      else
        ## NEED TO ABORT
        Chef::Log.warn("We are not connect to the primary, aborting ...")
        return
      end
    end

    # Want the node originating the connection to be included in the replicaset
    Chef::Log.info(members)
    found = false
    members.each_index do |n|
      if members[n]['name'] == node['name']
        found = true
      end
    end
    if found = false
      members << node
    end


    ## Lets get ready to reconfigure
    members.sort!{ |x,y| x.name <=> y.name }
    rs_members = []
    members.each_index do |n|
      port = members[n]['mongodb']['port']
      rs_members << {"_id" => n, "host" => "#{members[n]['fqdn']}:#{port}"}
    end

    Chef::Log.info(
      "Configuring replicaset with members #{members.collect{ |n| n['hostname'] }.join(', ')}"
    )

    rs_member_ips = []
    members.each_index do |n|
      port = members[n]['mongodb']['port']
      rs_member_ips << {"_id" => n, "host" => "#{members[n]['ipaddress']}:#{port}"}
    end

    # #1 - Get Current Configuration
    config = connection['local']['system']['replset'].find_one({"_id" => name})

    #2 - Increment document version
    config['version'] += 1
    
    #3 - Update Config
    config['members'] = rs_members

    #4 - Run replSetReconfig
    begin
      result = connection['admin'].command({:replSetReconfig => config}, :check_response => false)
    rescue
      if result.fetch('ok', nil) == 1
        Chef::Log.info("Replicaset reconfig worked")
      else
        Chef::Log.warn("Replicaset reconfig failed")
        Chef::Log.warn(result.fetch('errmsg', nil))
      end
    end
  end
  
  def self.configure_shards(node, shard_nodes)
    # lazy require, to move loading this modules to runtime of the cookbook
    require 'rubygems'
    require 'mongo'
    
    shard_groups = Hash.new{|h,k| h[k] = []}
    
    shard_nodes.each do |n|
      if n['recipes'].include?('mongodb::replicaset')
        key = "rs_#{n['mongodb']['shard_name']}"
      else
        key = '_single'
      end
      shard_groups[key] << "#{n['fqdn']}:#{n['mongodb']['port']}"
    end
    Chef::Log.info(shard_groups.inspect)
    
    shard_members = []
    shard_groups.each do |name, members|
      if name == "_single"
        shard_members += members
      else
        shard_members << "#{name}/#{members.join(',')}"
      end
    end
    Chef::Log.info(shard_members.inspect)
    
    begin
      connection = Mongo::Connection.new('localhost', node['mongodb']['port'], :op_timeout => 5)
    rescue Exception => e
      Chef::Log.warn("Could not connect to database: 'localhost:#{node['mongodb']['port']}', reason #{e}")
      return
    end
    
    admin = connection['admin']
    
    shard_members.each do |shard|
      cmd = BSON::OrderedHash.new
      cmd['addShard'] = shard
      begin
        result = admin.command(cmd, :check_response => false)
      rescue Mongo::OperationTimeout
        result = "Adding shard '#{shard}' timed out, run the recipe again to check the result"
      end
      Chef::Log.info(result.inspect)
    end
  end
  
  def self.configure_sharded_collections(node, sharded_collections)
    # lazy require, to move loading this modules to runtime of the cookbook
    require 'rubygems'
    require 'mongo'
    
    begin
      connection = Mongo::Connection.new('localhost', node['mongodb']['port'], :op_timeout => 5)
    rescue Exception => e
      Chef::Log.warn("Could not connect to database: 'localhost:#{node['mongodb']['port']}', reason #{e}")
      return
    end
    
    admin = connection['admin']
    
    databases = sharded_collections.keys.collect{ |x| x.split(".").first}.uniq
    Chef::Log.info("enable sharding for these databases: '#{databases.inspect}'")
    
    databases.each do |db_name|
      cmd = BSON::OrderedHash.new
      cmd['enablesharding'] = db_name
      begin
        result = admin.command(cmd, :check_response => false)
      rescue Mongo::OperationTimeout
        result = "enable sharding for '#{db_name}' timed out, run the recipe again to check the result"
      end
      if result['ok'] == 0
        # some error
        errmsg = result.fetch("errmsg")
        if errmsg == "already enabled"
          Chef::Log.info("Sharding is already enabled for database '#{db_name}', doing nothing")
        else
          Chef::Log.error("Failed to enable sharding for database #{db_name}, result was: #{result.inspect}")
        end
      else
        # success
        Chef::Log.info("Enabled sharding for database '#{db_name}'")
      end
    end
    
    sharded_collections.each do |name, key|
      cmd = BSON::OrderedHash.new
      cmd['shardcollection'] = name
      cmd['key'] = {key => 1}
      begin
        result = admin.command(cmd, :check_response => false)
      rescue Mongo::OperationTimeout
        result = "sharding '#{name}' on key '#{key}' timed out, run the recipe again to check the result"
      end
      if result['ok'] == 0
        # some error
        errmsg = result.fetch("errmsg")
        if errmsg == "already sharded"
          Chef::Log.info("Sharding is already configured for collection '#{name}', doing nothing")
        else
          Chef::Log.error("Failed to shard collection #{name}, result was: #{result.inspect}")
        end
      else
        # success
        Chef::Log.info("Sharding for collection '#{result['collectionsharded']}' enabled")
      end
    end
  
  end
  
end
