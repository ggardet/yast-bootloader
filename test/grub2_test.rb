require_relative "test_helper"

require "bootloader/grub2"

describe Bootloader::Grub2 do
  before do
    allow(::CFA::Grub2::Default).to receive(:new).and_return(double("GrubDefault").as_null_object)
    allow(::CFA::Grub2::GrubCfg).to receive(:new).and_return(double("GrubCfg").as_null_object)
    allow(Bootloader::Sections).to receive(:new).and_return(double("Sections").as_null_object)
    allow(Yast::BootStorage).to receive(:available_swap_partitions).and_return([])
    allow(Yast::BootStorage).to receive(:gpt_boot_disk?).and_return(false)
  end

  describe "#read" do
    before do
      allow(Bootloader::Stage1).to receive(:new).and_return(double.as_null_object)
      allow(Bootloader::DeviceMap).to receive(:new).and_return(double.as_null_object)
    end

    it "reads device map on legacy intel" do
      allow(Yast::Arch).to receive(:architecture).and_return("x86_64")

      device_map = double(Bootloader::DeviceMap)
      expect(device_map).to receive(:read)
      allow(Bootloader::DeviceMap).to receive(:new).and_return(device_map)

      subject.read
    end

    it "reads bootloader stage1 location" do
      stage1 = double(Bootloader::Stage1)
      expect(stage1).to receive(:read)
      allow(Bootloader::Stage1).to receive(:new).and_return(stage1)

      subject.read
    end
  end

  describe "write" do
    before do
      stage1 = double(Bootloader::Stage1, devices: [], generic_mbr?: false, write: nil)
      allow(Bootloader::Stage1).to receive(:new).and_return(stage1)
      allow(Bootloader::MBRUpdate).to receive(:new).and_return(double(run: nil))
      allow(Bootloader::GrubInstall).to receive(:new).and_return(double.as_null_object)
      allow(Bootloader::DeviceMap).to receive(:new).and_return(double.as_null_object)
    end

    it "writes stage1 location" do
      stage1 = double(Bootloader::Stage1, devices: [], generic_mbr?: false)
      expect(stage1).to receive(:write)
      allow(Bootloader::Stage1).to receive(:new).and_return(stage1)

      subject.write
    end

    it "changes pmbr flag as specified in pmbr_action for all boot devices with gpt label" do
      stage1 = double(Bootloader::Stage1, devices: ["/dev/sda", "/dev/sdb1"], generic_mbr?: false, write: nil)
      allow(Bootloader::Stage1).to receive(:new).and_return(stage1)

      allow(Yast::Storage).to receive(:GetDisk) do |_m, dev|
        case dev
        when "/dev/sda" then { "device" => "/dev/sda", "label" => "msdos" }
        when "/dev/sdb1" then { "device" => "/dev/sdb", "label" => "gpt" }
        else raise "unknown device #{dev}"
        end
      end

      expect(subject).to receive(:pmbr_setup).with("/dev/sdb")

      subject.write
    end

    it "runs grub2-install for all configured stage1 locations" do
      stage1 = double(Bootloader::Stage1, devices: ["/dev/sda", "/dev/sdb1"], generic_mbr?: false, write: nil)
      allow(Bootloader::Stage1).to receive(:new).and_return(stage1)

      grub2_install = double(Bootloader::GrubInstall)
      expect(grub2_install).to receive(:execute).with(devices: ["/dev/sda", "/dev/sdb1"])
      expect(Bootloader::GrubInstall).to receive(:new).with(efi: false).and_return(grub2_install)

      subject.write
    end

    context "on s390" do
      before do
        allow(Yast::Arch).to receive(:architecture).and_return("s390_64")
      end

      it "does not run mbr update for configured stage1 flags" do
        expect(Bootloader::MBRUpdate).to_not receive(:new)

        subject.write
      end
    end

    context "on other architectures" do
      before do
        allow(Yast::Arch).to receive(:architecture).and_return("x86_64")
      end

      it "runs mbr update for configured stage1 flags" do
        mbr_update = double(Bootloader::MBRUpdate)
        expect(mbr_update).to receive(:run)
        expect(Bootloader::MBRUpdate).to receive(:new).and_return(mbr_update)

        subject.write
      end
    end
  end

  context "#propose" do
    before do
      stage1 = double.as_null_object
      allow(Bootloader::Stage1).to receive(:new).and_return(stage1)
      allow(Bootloader::DeviceMap).to receive(:new).and_return(double.as_null_object)

      allow(Yast::BootStorage).to receive(:detect_disks)
    end

    it "proposes stage1" do
      stage1 = double
      expect(stage1).to receive(:propose)
      allow(Bootloader::Stage1).to receive(:new).and_return(stage1)

      subject.propose
    end

    it "propose to remove pmbr flag if boot disk is with gpt label" do
      allow(Yast::BootStorage).to receive(:gpt_boot_disk?).and_return(true)

      subject.propose

      expect(subject.pmbr_action).to eq :remove
    end

    it "propose to do not change pmbr flag if boot disk is not with gpt label" do
      allow(Yast::BootStorage).to receive(:gpt_boot_disk?).and_return(false)

      subject.propose

      expect(subject.pmbr_action).to eq :nothing
    end

  end

  describe "#name" do
    it "returns \"grub2\"" do
      expect(subject.name).to eq "grub2"
    end
  end

  describe "#packages" do
    it "return list containing grub2 package" do
      expect(subject.packages).to include("grub2")
    end

    it "returns list containing syslinux package if generic_mbr is used" do
      stage1 = double(generic_mbr?: true)
      allow(Bootloader::Stage1).to receive(:new).and_return(stage1)

      expect(subject.packages).to include("syslinux")
    end

    it "returns list without syslinux package if generic_mbr is not used" do
      stage1 = double(generic_mbr?: false)
      allow(Bootloader::Stage1).to receive(:new).and_return(stage1)

      expect(subject.packages).to_not include("syslinux")
    end

  end

  describe "#summary" do
    before do
      allow(Bootloader::UdevMapping).to receive(:to_kernel_device) { |d| d }
      allow(Yast::BootStorage).to receive(:can_boot_from_partition).and_return(true)
    end

    it "contain line saying that bootloader type is GRUB2" do
      expect(subject.summary).to include("Boot Loader Type: GRUB2")
    end
  end
end
