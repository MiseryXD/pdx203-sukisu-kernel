#!/usr/bin/env python3
"""Replace the kernel inside an Android boot.img (header v2) while keeping
ramdisk / dtb / Sony-embedded AVB vbmeta / AVB footer intact.

Layout of the original partition (pdx203):
    [image: hdr|kernel|ramdisk|dtb] [vbmeta blob] [zero padding] [AVB footer, 64B @ EOF]
"""
import sys, struct, hashlib

PAGE = 4096
FOOTER_SIZE = 64
FOOTER_MAGIC = b"AVBf"


def pr(n, p=PAGE):
    return ((n + p - 1) // p) * p


def be64(b, o):
    return struct.unpack_from(">Q", b, o)[0]


def main(orig_path, new_kernel_path, out_path):
    d = open(orig_path, "rb").read()
    if d[:8] != b"ANDROID!":
        sys.exit("not an Android boot image")

    u32 = lambda o: struct.unpack_from("<I", d, o)[0]
    kernel_size = u32(8)
    ramdisk_size = u32(16)
    second_size = u32(24)
    page = u32(36)
    hv = u32(40)
    header_size = u32(1644)
    dtb_size = u32(1648)
    rec_size = u32(1632)

    off = page
    kernel = d[off:off + kernel_size]; off += pr(kernel_size)
    ramdisk = d[off:off + ramdisk_size]; off += pr(ramdisk_size)
    second = d[off:off + second_size]; off += pr(second_size)
    dtb = d[off:off + dtb_size]; off += pr(dtb_size)
    dtbo = d[off:off + rec_size]

    old_img_size = page + pr(kernel_size) + pr(ramdisk_size) + pr(second_size) + pr(dtb_size) + pr(rec_size)

    footer = d[-FOOTER_SIZE:]
    has_footer = footer[:4] == FOOTER_MAGIC
    vbmeta = b""
    if has_footer:
        vb_off, vb_sz = be64(footer, 20), be64(footer, 28)
        vbmeta = d[vb_off:vb_off + vb_sz]
        print(f"AVB footer: image={be64(footer,12)} vbmeta@{vb_off} size={vb_sz} (blob {len(vbmeta)}B)")
    else:
        print("no AVB footer")

    new_kernel = open(new_kernel_path, "rb").read()
    print(f"orig kernel={kernel_size}B, new kernel={len(new_kernel)}B, delta={len(new_kernel)-kernel_size:+d}")

    # legacy 'id' field is informational (bootloaders do not verify it) — keep the
    # original bytes so a same-size rebuild is byte-identical to the source image
    hdr = bytearray(d[:header_size])
    struct.pack_into("<I", hdr, 8, len(new_kernel))

    out = bytearray()
    out += bytes(hdr).ljust(page, b"\x00")
    out += new_kernel.ljust(pr(len(new_kernel)), b"\x00")
    out += ramdisk.ljust(pr(len(ramdisk)), b"\x00")
    out += second.ljust(pr(len(second)), b"\x00")
    out += dtb.ljust(pr(len(dtb)), b"\x00")
    out += dtbo.ljust(pr(len(dtbo)), b"\x00")
    new_img_size = len(out)

    if has_footer:
        out += vbmeta
        out += b"\x00" * (len(d) - FOOTER_SIZE - len(out))
        f = bytearray(footer)
        struct.pack_into(">Q", f, 12, new_img_size)
        struct.pack_into(">Q", f, 20, new_img_size)
        out += bytes(f)
    else:
        out += b"\x00" * (len(d) - len(out))

    if len(out) != len(d):
        sys.exit(f"size mismatch: built {len(out)} vs partition {len(d)} "
                 f"(new image too big by {len(out)-len(d)} bytes)")

    open(out_path, "wb").write(out)
    print(f"wrote {out_path} ({len(out)} bytes)")
    print(f"  image={new_img_size} vbmeta@{new_img_size} sha256={hashlib.sha256(out).hexdigest()}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: repack_boot.py <orig boot.img> <new Image> <out boot.img>")
    main(*sys.argv[1:])
