package bootloaders

import "embed"

//go:embed *.efi *.kpxe bootenv/* wimboot
var Bootloaders embed.FS
