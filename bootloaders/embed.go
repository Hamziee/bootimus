package bootloaders

import "embed"

//go:embed ipxe.efi undionly.kpxe autoexec.ipxe wimboot
var Bootloaders embed.FS
