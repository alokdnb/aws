actions :auto_attach, :snapshot, :prune
default_action :auto_attach

state_attrs :aws_access_key,
            :disk_count,
            :disk_piops,
            :disk_size,
            :disk_type,
            :filesystem,
            :filesystem_options,
            :level,
            :mount_point,
            :mount_point_group,
            :mount_point_mode,
            :mount_point_owner,
            :snapshots,
            :disk_encrypted,
            :disk_kms_key_id

attribute :aws_access_key,        kind_of: String
attribute :aws_secret_access_key, kind_of: String
attribute :aws_session_token,     kind_of: String
attribute :aws_assume_role_arn,   kind_of: String
attribute :aws_role_session_name, kind_of: String
attribute :region,                kind_of: String
attribute :mount_point,           kind_of: String
attribute :mount_point_owner,     kind_of: String, default: 'root'
attribute :mount_point_group,     kind_of: String, default: 'root'
attribute :mount_point_mode,      kind_of: String, default: '0755'
attribute :disk_count,            kind_of: Integer
attribute :disk_size,             kind_of: Integer
attribute :level,                 default: 10
attribute :filesystem,            default: 'ext4'
attribute :filesystem_options,    default: 'rw,noatime,nobootwait'
attribute :snapshots,             default: []
attribute :snapshot_filters,      :kind_of => Hash, :default => {}
attribute :disk_type,             kind_of: String, default: 'standard'
attribute :disk_piops,            kind_of: Integer, default: 0
attribute :existing_raid,         kind_of: [TrueClass, FalseClass]
attribute :snapshots_to_keep,     kind_of: Integer, default: 2
attribute :snapshots_keep_hourlies,   :kind_of => Integer, :default => 24
attribute :snapshots_keep_dailies,    :kind_of => Integer, :default => 14
attribute :snapshots_keep_weeklies,   :kind_of => Integer, :default => 6
attribute :snapshots_keep_monthlies,  :kind_of => Integer, :default => 12
attribute :snapshots_keep_yearlies,   :kind_of => Integer, :default => 2
attribute :snapshot_timestamp,    :kind_of => Integer, :default => 0
attribute :disk_encrypted,        kind_of: [TrueClass, FalseClass], default: false
attribute :disk_kms_key_id,       kind_of: String
