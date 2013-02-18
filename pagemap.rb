#!/usr/bin/ruby

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
end

class PageRange
  attr_accessor :start
  attr_accessor :end
  attr_accessor :page_size
  def initialize(address)
    @start, @end = address.split("-")
    @start = @start.to_i(16)
    @end = @end.to_i(16)
    @page_size = `getconf PAGESIZE`.to_i
  end
  def to_s
    return @start.to_s(16)+"-"+@end.to_s(16)
  end
  def size
    return @end - @start
  end
  def number
    return (@end - @start)/@page_size
  end
  def each_page
    range = @start...@end
    range.step(@page_size) {|x|
      yield x
    }
  end
end
$pagemap = nil
class Map
  attr_accessor :address
  attr_accessor :perms
  attr_accessor :offset
  attr_accessor :device
  attr_accessor :inode
  attr_accessor :pathname
  attr_accessor :pages

  def Map.convert(line)
    address, perms, offset, device, inode, pathname = line.scan(/([0-9a-fA-F]+-[0-9a-fA-F]+)\s+([rwxsp-]+)\s+([0-9a-fA-F]+)\s+(\S+)\s+([0-9a-fA-F]+)\s+(\S*)/).first
    address = PageRange::new(address)
    offset = offset.to_i(16)
    inode = inode.to_i
    return Map::new(address, perms, offset, device, inode, pathname)
  end
  def initialize(address, perms, offset, device, inode, pathname)
    @address, @perms, @offset, @device, @inode, @pathname = address, perms, offset, device, inode, pathname
    @pages = {}
    @address.each_page{ |page|
      $pagemap.seek((page/@address.page_size)*8)
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

pid = ARGV[0]
$pagemap = File::open("/proc/#{pid}/pagemap")
maps_lines = File::open("/proc/#{pid}/maps")
maps = []
maps_lines.each { |line|
  maps.push(Map::convert(line))
}
maps.each { |map|
  puts map.to_s
  puts (map.address.size/1024).to_s + "kB"
  puts map.address.number.to_s
  map.address.each_page {|x| puts x.to_s(16) + " " + map.pages[x].to_s}
}
