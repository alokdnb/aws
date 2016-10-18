# TODO: Create ChefSpec for resource action prune.

class Resource
  attr_accessor :snapshots_to_keep,
                :snapshots_keep_hourlies,
                :snapshots_keep_dailies,
                :snapshots_keep_weeklies,
                :snapshots_keep_monthlies,
                :snapshots_keep_yearlies
end

new_resource = Resource.new

# How many hours need to keep one backup per hour.
new_resource.snapshots_keep_hourlies = 24

# How many days need to keep one backup per day.
new_resource.snapshots_keep_dailies = 14

# How many weeks need to keep one backup per week.
new_resource.snapshots_keep_weeklies = 6

# How many months need to keep one backup per month.
new_resource.snapshots_keep_monthlies = 12

# How many years need to keep one backup per year.
new_resource.snapshots_keep_yearlies = 2

# Maximum backups to keep
new_resource.snapshots_to_keep = 60


# datetime is Time object
def create_snap(datetime)
  {:aws_started_at => datetime.utc.strftime("%FT%T.000Z")}
end

def aws_time(time)
  time.utc.strftime("%FT%T.000Z")
end

require 'date'

time_start_point = Time.now
old_snapshots = Array.new (5 * 365 * 24 ) do |index|
  create_snap(time_start_point - 3600 * index)
end

snapshots_to_keep = []
datetime_now = DateTime.now - DateTime.now.offset

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

snapshots_to_keep = snapshots_to_keep.compact.sort{|a,b| b[:aws_started_at] <=> a[:aws_started_at]}.uniq.slice(0, new_resource.snapshots_to_keep)
puts snapshots_to_keep