include Opscode::Aws::Ec2

use_inline_resources

def whyrun_supported?
  true
end

action :create do
  raise 'Cannot create a volume with a specific volume_id as AWS chooses volume ids' if new_resource.volume_id

  snapshot_id = determine_snapshot_id
  # fetch volume data from node
  nvid = volume_id_in_node_data
  if nvid
    # volume id is registered in the node data, so check that the volume in fact exists in EC2
    vol = volume_by_id(nvid)
    exists = vol && vol[:state] != 'deleting'
    # TODO: determine whether this should be an error or just cause a new volume to be created. Currently erring on the side of failing loudly
    raise "Volume with id #{nvid} is registered with the node but does not exist in EC2. To clear this error, remove the ['aws']['ebs_volume']['#{new_resource.name}']['volume_id'] entry from this node's data." unless exists
  else
    # Determine if there is a volume that meets the resource's specifications and is attached to the current
    # instance in case a previous [:create, :attach] run created and attached a volume but for some reason was
    # not registered in the node data (e.g. an exception is thrown after the attach_volume request was accepted
    # by EC2, causing the node data to not be stored on the server)
    if new_resource.device && (attached_volume = currently_attached_volume(instance_id, new_resource.device)) # rubocop: disable Style/IfInsideElse
      Chef::Log.debug("There is already a volume attached at device #{new_resource.device}")
      compatible = volume_compatible_with_resource_definition?(attached_volume)
      raise "Volume #{attached_volume.volume_id} attached at #{attached_volume.attachments[0].device} but does not conform to this resource's specifications" unless compatible
      Chef::Log.debug("The volume matches the resource's definition, so the volume is assumed to be already created")
      converge_by("update the node data with volume id: #{attached_volume.volume_id}") do
        node.set['aws']['ebs_volume'][new_resource.name]['volume_id'] = attached_volume.volume_id
        node.save unless Chef::Config[:solo]
      end
    else
      # If not, create volume and register its id in the node data
      converge_message = "create a #{new_resource.size}GB volume in #{aws_region} "
      converge_message += "using snapshot #{new_resource.snapshot_id} " if new_resource.snapshot_id
      converge_message += "and update the node data with created volume's id"
      converge_by(converge_message) do
        nvid = create_volume(new_resource.snapshot_id,
                             new_resource.size,
                             new_resource.availability_zone,
                             new_resource.timeout,
                             new_resource.volume_type,
                             new_resource.piops,
                             new_resource.encrypted,
                             new_resource.kms_key_id)
        node.set['aws']['ebs_volume'][new_resource.name]['volume_id'] = nvid
        node.save unless Chef::Config[:solo]
        
        aws_resource_tag nvid do
          action :update
          aws_access_key        new_resource.aws_access_key
          aws_secret_access_key new_resource.aws_secret_access_key
          tags "Name" => new_resource.name
        end
      end
    end
  end
end

action :attach do
  # determine_volume returns a Hash, not a Mash, and the keys are
  # symbols, not strings.
  vol = determine_volume

  if vol[:state] == 'in-use'
    Chef::Log.info("Vol: #{vol}")
    vol[:attachments].each do |attachment|
      if attachment[:instance_id] != instance_id
        raise "Volume with id #{vol[:volume_id]} exists but is attached to instance #{attachment[:instance_id]}"
      else
        Chef::Log.debug('Volume is already attached')
      end
    end
  else
    converge_by("attach the volume #{vol[:volume_id]} to instance #{instance_id} as #{new_resource.device} and update the node data with created volume's id") do
      # attach the volume and register its id in the node data
      attach_volume(vol[:volume_id], instance_id, new_resource.device, new_resource.timeout)
      mark_delete_on_termination(new_resource.device, vol[:volume_id], instance_id) if new_resource.delete_on_termination
      # always use a symbol here, it is a Hash
      node.set['aws']['ebs_volume'][new_resource.name]['volume_id'] = vol[:volume_id]
      node.save unless Chef::Config[:solo]
    end
  end
end

action :detach do
  vol = determine_volume
  converge_by("detach volume with id: #{vol[:volume_id]}") do
    detach_volume(vol[:volume_id], new_resource.timeout)
  end
end

action :delete do
  vol = determine_volume
  converge_by("delete volume with id: #{vol[:volume_id]}") do
    delete_volume(vol[:volume_id], new_resource.timeout)
  end
end

action :snapshot do
  vol = determine_volume
  converge_by("would create a snapshot for volume: #{vol[:aws_id]}") do
    begin
      if (mount_point = discover_mount_point(vol[:aws_device]))
        Chef::Log.info "[aws_ebs_volume.snapshot] Freeze #{mount_point}"
        freeze_fs(mount_point)
      end
      snapshot = ec2.create_snapshot(vol[:aws_id],new_resource.description)
    ensure
      if mount_point
        Chef::Log.info "[aws_ebs_volume.snapshot] Unfreeze #{mount_point}"
        unfreeze_fs(mount_point)
      end
    end
    Chef::Log.info("Created snapshot of #{vol[:aws_id]} as #{snapshot[:aws_id]}")
    node.set['aws']['ebs_volume'][new_resource.name]['snapshots'] = (node['aws']['ebs_volume'][new_resource.name]['snapshots'] || []) + [snapshot[:aws_id]]
    node.save unless Chef::Config[:solo]

    tags = Hash[new_resource.snapshot_filters.select{|x| x.start_with?("tag:")}.map{|k, v| [k[4..-1], v]}]
    tags.merge!('timestamp' => Time.now.to_i.to_s)
    volume_name = new_resource.name
    aws_resource_tag "Tagging the latest snapshot of volume #{vol[:aws_id]}" do
      action :add
      aws_access_key node['coupa-storage']['aws_access_key']
      aws_secret_access_key node['coupa-storage']['aws_secret_key']
      resource_id lazy { node['aws']['ebs_volume'][volume_name]['snapshots'].last }
      tags tags
    end

  end
end

action :prune do
  require 'date'
  vol = determine_volume if new_resource.snapshot_filters.empty?
  old_snapshots = []
  snapshots_to_keep = Array.new
  datetime_now = DateTime.now - DateTime.now.offset
  Chef::Log.info 'Checking for old snapshots'
  ec2.describe_snapshots(:filters => new_resource.snapshot_filters).sort { |a,b| b[:aws_started_at] <=> a[:aws_started_at] }.each do |snapshot|
    if (!new_resource.snapshot_filters.empty?) || (snapshot[:aws_volume_id] == vol[:aws_id])
      Chef::Log.info "Found old snapshot #{snapshot[:volume_id]} (#{snapshot[:volume_id]}) #{snapshot[:start_time]}"
      old_snapshots << snapshot
    end
  end
  (1..new_resource.snapshots_keep_yearlies).each do |y|
    dd = datetime_now.prev_year(y)
    snapshots_to_keep << old_snapshots.select {|x|
      DateTime.strptime(x[:aws_started_at], "%FT%T.000Z").year == dd.year
    }.first
  end

  (1..new_resource.snapshots_keep_monthlies).each do |m|
    dd = datetime_now.prev_month(m)
    snapshots_to_keep << old_snapshots.select {|x|
      sd = DateTime.strptime(x[:aws_started_at], "%FT%T.000Z")
      sd.month == dd.month && sd.year == dd.year
    }.first
  end

  (1..new_resource.snapshots_keep_weeklies).each do |w|
    dd = datetime_now.prev_day(w*7)
    snapshots_to_keep << old_snapshots.select {|x|
      sd = DateTime.strptime(x[:aws_started_at], "%FT%T.000Z")
      sd.year == dd.year && sd.cweek == dd.cweek
    }.first
  end

  (1..new_resource.snapshots_keep_dailies).each do |d|
    dd = datetime_now.prev_day(d)
    snapshots_to_keep << old_snapshots.select {|x|
      sd = DateTime.strptime(x[:aws_started_at], "%FT%T.000Z")
      sd.year == dd.year && sd.month == dd.month && sd.day == dd.day
    }.first
  end

  (0..new_resource.snapshots_keep_hourlies).each do |h|
    dd = datetime_now - Rational(h, 24)
    snapshots_to_keep << old_snapshots.select {|x|
      sd = DateTime.strptime(x[:aws_started_at], "%FT%T.000Z")
      sd.year == dd.year && sd.month == dd.month && sd.day == dd.day && sd.hour == dd.hour
    }.first
  end

  node_snapshots = (node['aws']['ebs_volume'][new_resource.name]['snapshots'] || []).dup
  snapshots_to_keep = snapshots_to_keep.compact.sort{|a,b| b[:aws_started_at] <=> a[:aws_started_at]}.uniq.slice(0, new_resource.snapshots_to_keep)
  (old_snapshots - snapshots_to_keep).each do |die|
    converge_by("delete snapshot with id: #{die[:aws_id]}") do
      Chef::Log.info "Deleting old snapshot #{die[:aws_id]}"
      ec2.delete_snapshot(die[:aws_id])
      node_snapshots.delete(die[:aws_id])
    end
  end
  node.set['aws']['ebs_volume'][new_resource.name]['snapshots'] = node_snapshots
  node.save unless Chef::Config[:solo]
  
  new_resource.updated_by_last_action(true)
end

private

def volume_id_in_node_data
  node['aws']['ebs_volume'][new_resource.name]['volume_id']
rescue NoMethodError
  nil
end

# Pulls the volume id from the volume_id attribute or the node data and verifies that the volume actually exists
def determine_volume
  vol_id = new_resource.volume_id || volume_id_in_node_data || ( (vol = currently_attached_volume(instance_id, new_resource.device) ) ? vol[:aws_id] : nil )
  raise 'volume_id attribute not set and no volume id is set in the node data for this resource (which is populated by action :create) and no volume is attached at the device' unless vol_id

  # check that volume exists
  vol = volume_by_id(vol_id)
  raise "No volume with id #{vol_id} exists" unless vol

  vol
end

def determine_snapshot_id
  if new_resource.snapshot_id =~ /vol/
    new_resource.snapshot_filters({ 'volume-id' => new_resource.snapshot_id })
  end

  if new_resource.snapshot_id.nil? && !new_resource.snapshot_filters.empty?
    new_resource.snapshot_id(find_snapshot_id(new_resource.snapshot_filters, new_resource.most_recent_snapshot, :timestamp => new_resource.snapshot_timestamp))  end

  new_resource.snapshot_id
end

# Retrieves information for a volume
def volume_by_id(volume_id)
  ec2.describe_volumes(:filters => { 'volume-id' => volume_id }).first
end

# Returns the volume that's attached to the instance at the given device or nil if none matches
def currently_attached_volume(instance_id, device)
  ec2.describe_volumes(
    filters: [
      { name: 'attachment.device', values: [device] },
      { name: 'attachment.instance-id', values: [instance_id] }
    ]
  ).volumes[0]
end

# Returns true if the given volume meets the resource's attributes
def volume_compatible_with_resource_definition?(volume)
  determine_snapshot_id
  (new_resource.size.nil? || new_resource.size == volume[:aws_size]) &&
  (new_resource.availability_zone.nil? || new_resource.availability_zone == volume[:zone])
end

# Creates a volume according to specifications and blocks until done (or times out)
def create_volume(snapshot_id, size, availability_zone, timeout, volume_type, piops, encrypted, kms_key_id)
  availability_zone ||= instance_availability_zone

  # Sanity checks so we don't shoot ourselves.
  raise "Invalid volume type: #{volume_type}" unless %w(standard io1 gp2 sc1 st1).include?(volume_type)

  params = { availability_zone: availability_zone, volume_type: volume_type, encrypted: encrypted, kms_key_id: kms_key_id }
  # PIOPs requested. Must specify an iops param and probably won't be "low".
  if volume_type == 'io1'
    raise 'IOPS value not specified.' unless piops >= 100
    params[:iops] = piops
  end

  # Shouldn't see non-zero piops param without appropriate type.
  if piops > 0
    raise 'IOPS param without piops volume type.' unless volume_type == 'io1'
  end

  params[:snapshot_id] = snapshot_id if snapshot_id
  params[:size] = size if size

  nv = ec2.create_volume(params)
  Chef::Log.debug("Created new #{nv[:encrypted] ? 'encryped' : ''} volume #{nv[:volume_id]}#{snapshot_id ? " based on #{snapshot_id}" : ''}")

  # block until created
  begin
    Timeout.timeout(timeout) do
      loop do
        vol = volume_by_id(nv[:volume_id])
        if vol && vol[:state] != 'deleting'
          if ['in-use', 'available'].include?(vol[:state])
            Chef::Log.info("Volume #{nv[:volume_id]} is available")
            break
          else
            Chef::Log.debug("Volume is #{vol[:state]}")
          end
          sleep 3
        else
          raise "Volume #{nv[:volume_id]} no longer exists"
        end
      end
    end
  rescue Timeout::Error
    raise "Timed out waiting for volume creation after #{timeout} seconds"
  end

  nv[:volume_id]
end

# Attaches the volume and blocks until done (or times out)
def attach_volume(volume_id, instance_id, device, timeout)
  Chef::Log.debug("Attaching #{volume_id} as #{device}")
  ec2.attach_volume(volume_id: volume_id, instance_id: instance_id, device: device)

  # block until attached
  begin
    Timeout.timeout(timeout) do
      loop do
        vol = volume_by_id(volume_id)
        if vol && vol[:state] != 'deleting'
          attachment = vol[:attachments].find { |a| a[:state] == 'attached' }
          if !attachment.nil?
            if attachment[:instance_id] == instance_id
              Chef::Log.info("Volume #{volume_id} is attached to #{instance_id}")
              break
            else
              raise "Volume is attached to instance #{vol[:aws_instance_id]} instead of #{instance_id}"
            end
          else
            Chef::Log.debug("Volume is #{vol[:state]}")
          end
          sleep 3
        else
          raise "Volume #{volume_id} no longer exists"
        end
      end
    end
  rescue Timeout::Error
    raise "Timed out waiting for volume attachment after #{timeout} seconds"
  end
end

if ::File.exists?(device) && IO.popen("/sbin/blkid #{device}"){|x| x.read.match(/TYPE="ext[0-9]"/)}
    volume_size = (r = ec2.describe_volumes(:filters => {'volume-id' => volume_id}).first)[:aws_size]
    snapshot_size = (ec2.describe_snapshots(:filters => {'snapshot-id' => r[:snapshot_id]}).first ||{})[:aws_volume_size]
    if volume_size.nil? || snapshot_size.nil?
      Chef::Log.error "Cannot determine size of volume or snapshot. #{volume_size}, #{snapshot_size}"
    elsif volume_size == snapshot_size
      Chef::Log.info "Resize volume action is not required"
    else
      Chef::Log.info "Resize volume is required. Performing..."
      resize2fs(device)
    end
  elsif !::File.exists?(device)
    Chef::Log.error "Expected to see #{device} to perform resizing."
  end
end

# Detaches the volume and blocks until done (or times out)
def detach_volume(volume_id, timeout)
  vol = volume_by_id(volume_id)
  attachment = vol[:attachments].find { |a| a[:instance_id] == instance_id }
  if attachment.nil?
    attached_instance_ids = vol[:attachments].collect { |a| a[:instance_id] }
    Chef::Log.debug("EBS Volume #{volume_id} is not attached to this instance (attached to #{attached_instance_ids}). Skipping...")
    return
  end
  Chef::Log.debug("Detaching #{volume_id}")
  orig_instance_id = attachment[:instance_id]
  ec2.detach_volume(volume_id: volume_id)

  # block until detached
  begin
    Timeout.timeout(timeout) do
      loop do
        vol = volume_by_id(volume_id)
        if vol && vol[:state] != 'deleting'
          poll_attachment = vol[:attachments].find { |a| a[:instance_id] == instance_id }
          if poll_attachment.nil?
            Chef::Log.info("Volume detached from #{orig_instance_id}")
            break
          else
            Chef::Log.debug("Volume: #{vol.inspect}")
          end
        else
          Chef::Log.debug("Volume #{volume_id} no longer exists")
          break
        end
        sleep 3
      end
    end
  rescue Timeout::Error
    raise "Timed out waiting for volume detachment after #{timeout} seconds"
  end
end

# Deletes the volume and blocks until done (or times out)
def delete_volume(volume_id, timeout)
  vol = volume_by_id(volume_id)
  raise "Cannot delete volume #{volume_id} as it is currently attached to #{vol[:attachments].size} node(s)" unless vol[:attachments].empty?

  Chef::Log.debug("Deleting #{volume_id}")
  ec2.delete_volume(volume_id: volume_id)

  # block until deleted
  begin
    Timeout.timeout(timeout) do
      loop do
        vol = volume_by_id(volume_id)
        if vol[:state] == 'deleting' || vol[:state] == 'deleted'
          Chef::Log.debug("Volume #{volume_id} entered #{vol[:state]} state")
          node.set['aws']['ebs_volume'][new_resource.name] = {}
          break
        end
        sleep 3
      end
    end
  rescue Timeout::Error
    raise "Timed out waiting for volume to enter after #{timeout} seconds"
  end
end

def mark_delete_on_termination(device_name, volume_id, instance_id)
  Chef::Log.debug("Marking volume #{volume_id} with device name #{device_name} attached to instance #{instance_id} #{new_resource.delete_on_termination} for deletion on instance termination")
  ec2.modify_instance_attribute(block_device_mappings: [{ device_name: device_name, ebs: { volume_id: volume_id, delete_on_termination: new_resource.delete_on_termination } }], instance_id: instance_id)
end
