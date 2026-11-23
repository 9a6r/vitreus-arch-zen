
# Project settings appended to Arch's releng profile.
iso_name="vitreus-arch-zen"
iso_label="VITREUS_ZEN"
iso_publisher="Vitreus Arch Zen community build"
iso_application="Vitreus on Arch Linux with the Zen kernel"
arch="x86_64"
# Compress files in independent blocks. A changed file will not force other
# small files sharing a compressed fragment to change with it.
airootfs_image_type="squashfs"
airootfs_image_tool_options=(-comp zstd -Xcompression-level 12 -b 128K -no-fragments)
file_permissions["/etc/gshadow"]="0:0:400"
file_permissions["/etc/sudoers.d/10-vitreus-live"]="0:0:440"
