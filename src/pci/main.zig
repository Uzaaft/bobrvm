//! PCI subsystem.
//!
//! Provides PCIe ECAM host bridge and virtio-pci devices for UEFI boot support.

pub const ecam = @import("ecam.zig");
pub const virtio_pci = @import("virtio_pci.zig");

pub const EcamHost = ecam.EcamHost;
pub const PciDevice = ecam.PciDevice;
pub const EcamAddr = ecam.EcamAddr;

pub const VirtioPciDevice = virtio_pci.VirtioPciDevice;
pub const VirtioPciTransport = virtio_pci.VirtioPciTransport;

pub const ECAM_BASE = ecam.ECAM_BASE;
pub const ECAM_SIZE = ecam.ECAM_SIZE;
pub const PCI_MMIO_BASE = ecam.PCI_MMIO_BASE;
pub const PCI_MMIO_SIZE = ecam.PCI_MMIO_SIZE;

pub const ecamMmioRead = ecam.ecamMmioRead;
pub const ecamMmioWrite = ecam.ecamMmioWrite;

test {
    _ = ecam;
    _ = virtio_pci;
}
