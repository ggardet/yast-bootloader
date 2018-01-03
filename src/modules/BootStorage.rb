# encoding: utf-8

# File:
#      modules/BootStorage.ycp
#
# Module:
#      Bootloader installation and configuration
#
# Summary:
#      Module includes specific functions for handling storage data.
#      The idea is handling all storage data necessary for bootloader
#      in one module.
#
# Authors:
#      Jozef Uhliarik <juhliarik@suse.cz>
#
#
#
#
require "yast"
require "storage"
require "y2storage"
require "bootloader/udev_mapping"
require "bootloader/exceptions"

module Yast
  class BootStorageClass < Module
    include Yast::Logger

    # Moint point for /boot. If there is not separated /boot, / is used instead.
    # @return [Y2Storage::Filesystem]
    def boot_mountpoint
      detect_disks

      @boot_fs
    end

    def main
      textdomain "bootloader"

      Yast.import "Arch"
      Yast.import "Mode"

      # FATE#305008: Failover boot configurations for md arrays with redundancy
      # list <string> includes physical disks used for md raid

      @md_physical_disks = []

      # Revision to recognize if cached values are still valid
      @storage_revision = nil
    end

    def storage_changed?
      @storage_revision != Y2Storage::StorageManager.instance.staging_revision
    end

    def staging
      Y2Storage::StorageManager.instance.staging
    end

    def storage_read?
      !@storage_revision.nil?
    end

    def gpt_boot_disk?
      require "bootloader/bootloader_factory"
      current_bl = ::Bootloader::BootloaderFactory.current

      # efi require gpt disk, so it is always one
      return true if current_bl.name == "grub2efi"
      # if bootloader do not know its location, then we do not care
      return false unless current_bl.respond_to?(:stage1)

      targets = current_bl.stage1.devices
      boot_disks = staging.disks.select { |d| targets.any? { |t| d.name_or_partition?(t) } }

      boot_disks.any? { |disk| disk.gpt? }
    end

    # FIXME: merge with BootSupportCheck
    # Check if the bootloader can be installed at all with current configuration
    # @return [Boolean] true if it can
    def bootloader_installable?
      true
    end

    # Sets properly boot, root and mbr disk.
    # resets disk configuration. Clears cache from #detect_disks
    def reset_disks
      @boot_fs = nil
    end

    def prep_partitions
      partitions = Y2Storage::Partitionable.all(staging).map(&:prep_partitions).flatten
      log.info "detected prep partitions #{partitions.inspect}"
      partitions
    end

    # Get map of swap partitions
    # @return a map where key is partition name and value its size in KiB
    def available_swap_partitions
      ret = {}

      staging.filesystems.select { |f| f.type.is?(:swap) }.each do |swap|
        blk_device = swap.blk_devices[0]
        ret[blk_device.name] = blk_device.size.to_i / 1024
      end

      log.info "Available swap partitions: #{ret}"
      ret
    end

    def encrypted_boot?
      fs = boot_mountpoint
      log.info "boot mp = #{fs.inspect}"
      # check if fs is on an encryption
      result = fs.ancestors.any? { |a| a.is?(:encryption) }

      log.info "encrypted_boot? = #{result}"

      result
    end

    # get suitable device for stage1 by string name
    # @param [String] dev_name device name
    # @return [Array<Y2Storage::Device>] list of suitable devices
    def stage1_device_for_name(dev_name)
      device = staging.find_by_name(dev_name)
      raise "unknown device #{dev_name}" unless device

      if device.is?(:partition) || device.is?(:filesystem)
        stage1_partitions_for(device)
      else
        stage1_disks_for(device)
      end
    end

    # get stage1 device suitable for stage1 location
    # ( so e.g. exclude logical partition and use instead extended ones )
    # @param [Y2Storage::Device] device to check
    # @return [Array<Y2Storage::Device] devices suitable for stage1
    def stage1_partitions_for(device)
      # so how to do search? at first find first partition with parents
      # that is on disk or multipath (as ancestors method is not sorted)
      to_process = [device]
      partitions = []
      loop do
        break if to_process.empty?
        partition = to_process.pop
        if partition.is?(:partition)
          partitionable = partition.partitionable
          if partitionable.is?(:disk) || partitionable.is?(:multipath)
            partitions << partition
            next # we are done here, we found partition for this part
          end
        end
        to_process.concat(partition.parents)
      end

      # now replace all logical partitions for extended
      partitions.map! { |p| extended_for_logical(p) }
      partitions.uniq!

      log.info "stage1 partitions for #{device.inspect} is #{partitions.inspect}"

      partitions
    end

    # If passed partition is logical, return extended, otherwise return argument
    def extended_for_logical(partition)
      if partition.type.is?(:logical)
        partition = extended_partition(partition)
      end

      partition
    end

    # get stage1 device suitable for stage1 location
    # @param [Y2Storage::Device] device to check
    # @return [Array<Y2Storage::Device] devices suitable for stage1
    def stage1_disks_for(device)
      disks = ([device] + device.ancestors + device.descendants).select { |a| a.is?(:disk) }
      # filter out multipath wires and instead place there its mutlipath device
      multipaths = ([device] + device.ancestors + device.descendants).select { |a| a.is?(:multipath) }

      multipath_wires = multipaths.each_with_object([]) { |m, r| r.concat(m.parents) }

      result = multipaths + disks - multipath_wires

      log.info "stage1 disks for #{device.inspect} is #{result.inspect}"

      result
    end

    # shortcut to get stage1 disks for /boot
    def boot_disks
      stage1_disks_for(boot_mountpoint)
    end

    # shortcut to get stage1 partitions for /boot
    def boot_partitions
      stage1_partitions_for(boot_mountpoint)
    end

  private

    def detect_disks
      return if @boot_fs && !storage_changed? # quit if already detected

      @boot_fs = find_mountpoint("/boot")
      @boot_fs ||= find_mountpoint("/")

      raise ::Bootloader::NoRoot, "Missing '/' mount point" unless @boot_fs

      log.info "boot fs #{@boot_fs.inspect}"

      @storage_revision = Y2Storage::StorageManager.instance.staging_revision
    end

    def extended_partition(partition)
      part = partition.partitionable.partitions.find { |p| p.type.is?(:extended) }
      return nil unless part

      log.info "Using extended partition instead: #{part.inspect}"
      part
    end

    # Find the filesystem mounted to given mountpoint.
    def find_mountpoint(mountpoint)
      staging.filesystems.find { |f| f.mountpoint == mountpoint }
    end
  end

  BootStorage = BootStorageClass.new
  BootStorage.main
end
