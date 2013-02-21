#!/usr/bin/ruby
require 'optparse'

begin
  $kpagecount = File::open("/proc/kpagecount")
rescue Exception => e
  $kpagecount = nil
end

begin
  $kpageflags = File::open("/proc/kpageflags")
rescue Exception => e
  $kpageflags = nil
end

class Flags
  attr_accessor :value
  FLAGS = ["LOCKED", "ERROR", "REFERENCED", "UPTODATE", "DIRTY", "LRU", "ACTIVE", "SLAB", "WRITEBACK", "RECLAIM", "BUDDY", "MMAP", "ANON", "SWAPCACHE", "SWAPBACKED", "COMPOUND_HEAD", "COMPOUND_TAIL", "HUGE", "UNEVICTABLE", "HWPOISON", "NOPAGE", "KSM"]
  def initialize(value)
    @value = value
  end
  def to_s
    val = @value
    flags = []
    FLAGS.each{ |flag|
      flags.push(flag) if (val & 1) == 1
      val = val >> 1
    }
    return flags.join(" ")
  end
end
class Page
  attr_accessor :pfn, :swap_type, :swap_offset, :page_shift, :reserved, :swapped, :present, :count, :flags
  def Page.decode(code)
    present = ((code >> 63) & 1) == 1
    swapped = ((code >> 62) & 1) == 1
    reserved = ((code >> 61) & 1) == 1
    pfn = code & 0x7fffffffffffff
    swap_type = code & 0x1f
    swap_offset = (code & 0x7fffffffffffe0) >> 5
    page_shift = (code >> 55) & 0x3f
    return Page::new(pfn, swap_type, swap_offset, page_shift, reserved, swapped, present)
  end
  def initialize(pfn, swap_type, swap_offset, page_shift, reserved, swapped, present)
    @pfn, @swap_type, @swap_offset, @page_shift, @reserved, @swapped, @present = pfn, swap_type, swap_offset, page_shift, reserved, swapped, present
    @count = nil
    if $kpagecount and @present then
      $kpagecount.seek(@pfn*8)
      str = $kpagecount.read(8)
      if str then
        @count = str.unpack('Q').first
      end
    end
    @flags = nil
    if $kpageflags and @present then
      $kpageflags.seek(@pfn*8)
      str = $kpageflags.read(8)
      if str then
        @flags = Flags::new(str.unpack('Q').first)
      end
    end
  end
  def to_s
    s = ""
    if @present then
      s += (@pfn << @page_shift).to_s(16)
      s += " " + @count.to_s if @count
      s += " " + @flags.to_s if @flags
      return s
    end 
    return "swapped" if @swapped
    return "absent"
  end
  def absent
    return ((!@present) && (!@swapped))
  end
end

class PageRange
  attr_accessor :start
  attr_accessor :end
  def initialize(address)
    @start, @end = address.split("-")
    @start = @start.to_i(16)
    @end = @end.to_i(16)
  end
  def to_s
    return @start.to_s(16)+"-"+@end.to_s(16)
  end
  def size
    return @end - @start
  end
  def number
    return (@end - @start)/$page_size
  end
  def each_page
    range = @start...@end
    range.step($page_size) {|x|
      yield x
    }
  end
end
class Map
  attr_accessor :address
  attr_accessor :perms
  attr_accessor :offset
  attr_accessor :device
  attr_accessor :inode
  attr_accessor :pathname
  attr_accessor :pages

  def Map.convert(line,match="")
    address, perms, offset, device, inode, pathname = line.scan(/([0-9a-fA-F]+-[0-9a-fA-F]+)\s+([rwxsp-]+)\s+([0-9a-fA-F]+)\s+(\S+)\s+([0-9a-fA-F]+)\s+(\S*)/).first
    address = PageRange::new(address)
    offset = offset.to_i(16)
    inode = inode.to_i
    return Map::new(address, perms, offset, device, inode, pathname) if pathname.match(match)
    return nil
  end
  def initialize(address, perms, offset, device, inode, pathname)
    @address, @perms, @offset, @device, @inode, @pathname = address, perms, offset, device, inode, pathname
    @pages = {}
    @address.each_page{ |page|
      $pagemap.seek((page/$page_size)*8)
      str = $pagemap.read(8)
      if str then
        @pages[page] = Page::decode(str.unpack('Q').first)
      end
    }
  end
  def to_s
    return @address.to_s + " " + @perms + " " + @offset.to_s(16) + " " + @device + " " + @inode.to_s + " " + @pathname
  end
end

def usage(msg=nil)
  puts msg if msg
  puts $parser.to_s
  exit(0)
end

$options = {:match => "", :base => 16}

$parser = OptionParser::new do |opts|
  opts.banner = "Usage: pagemap.rb [options] [pid [address[,adress...]]]"
  opts.on("-b", "--base [BASE]", Integer, "Address base") do |base|
    $options[:base] = base
  end
  opts.on("-y", "--[no-]yaml","YAML output") do |yaml|
    $options[:yaml] = yaml
  end
  opts.on("-m", "--match [MATCH]", "Pathname match") do |match|
    $options[:match] = match
  end
  opts.on("-a", "--[no-]all", "list absent pages") do |v|
    $options[:all] = true
  end
  opts.on("-h", "--help", "Show this message") do
    puts opts
    exit
  end
  opts.parse!
end
addresses = nil

if ARGV.length > 2 then
  usage("Invalid number of arguments (#{ARGV.length})!")
end

if ARGV.length == 0 then
  pid = Process.ppid
else
  pid = ARGV[0]
  pid = pid.to_i
  if pid == 0 then
    usage("Invalid pid!")
  end
end

addresses = ARGV[1].split(",") if ARGV.length == 2

$page_size = `getconf PAGESIZE`.to_i
$pagemap = File::open("/proc/#{pid}/pagemap")

if addresses then
  pages = {}
  addresses.each { |address|
    page = nil
    $pagemap.seek((address.to_i($options[:base])/$page_size)*8)
    str = $pagemap.read(8)
    if str then
      page = Page::decode(str.unpack('Q').first)
    end
    pages[address] = page
  }
  if $options[:yaml] then
    require 'yaml'
    puts YAML::dump(pages)
  else
    addresses.each { |address|
      p = pages[address]
      if p && (!p.absent || $options[:all]) then
        puts address.to_i($options[:base]).to_s(16) + " " + p.to_s
      end
    }
  end
else
  maps_lines = File::open("/proc/#{pid}/maps")
  maps = []
  maps_lines.each { |line|
    map = Map::convert(line,$options[:match])
    maps.push(map) if map
  }
  if $options[:yaml] then
    require 'yaml'
    puts YAML::dump(maps)
  else
    maps.each { |map|
      puts '## mapping: ' + map.to_s
      puts '## mapping size: ' + (map.address.size/1024).to_s + "kB" +
	' / number of pages: ' + map.address.number.to_s
      map.address.each_page {|x| 
        p = map.pages[x]
        if p && (!p.absent || $options[:all]) then
          puts x.to_s(16) + " " + p.to_s
        end
      }
    }
  end
end
