---
summary: Draft upstream issue for pydicom. 1-bit OW Pixel Data in Explicit VR Big Endian is decoded without the 16-bit word swap PS3.5 requires; DCMTK swaps. Also notes OB over 8 bits in Big Endian (non-conformant) read in Big Endian order. Found settling blueprint F46; verified on pydicom 3.0.2 and main. Not yet posted.
read_when:
  - posting or following up upstream pydicom issues
  - changing how dartdicom decodes or writes Big Endian Pixel Data (blueprint F46, I-18)
---

# Draft: pydicom reads 1-bit OW Big Endian Pixel Data unswapped

**Target:** `pydicom/pydicom`, template *Pixel Data issue* (`pixel_issue.md`, label `pixel-data`).

**Status:** not posted; it needs review before it goes out under a maintainer's account. Lifecycle (docs/issues is a staging shelf): post it, then delete this file and leave the issue number in the commit.

**Checked before posting (2026-10-18):**
- **Verified:**
  - reproduced on pydicom 3.0.2 and on main at `a6374203fe` (2026-10-14). In main the condition is the same: `be_swap_ow` requires `bits_allocated // 8 == 1`;
  - DCMTK 3.7.0's behavior, as in the text below.
- **Searched:** keyword searches of pydicom's issues ("big endian OW 1-bit", "be_swap_ow", "big endian 1 bit") found no match. Keyword search is not exhaustive.
- **Not verified:** any Big Endian 1-bit file from a real device; pydicom's encoders (only decoding was checked).

**Effect on dartdicom:** `dartdicom_pixel` follows PS3.5 and DCMTK here, not pydicom (blueprint F46, `decode/native.dart`). I-18's pydicom reading is therefore not the check for this case.

---

## Issue text

**Title:** 1-bit OW Pixel Data in Explicit VR Big Endian is decoded without swapping its 16-bit words

**Describe the issue**

PS3.5 packs native pixel cells into words for OW, Bits Allocated 1 included, and the byte order of those words follows the transfer syntax:

> "For Pixel Data (7FE0,0010) encoded with the Value Representation OW, the byte ordering of the resulting 2-byte words is defined by the Little Endian or Big Endian Transfer Syntaxes negotiated at the Association Establishment"
>
> DICOM PS3.5 2016b §8.2, https://dicom.nema.org/medical/dicom/2016b/output/chtml/part05/chapter_8.html#sect_8.2 (2016b is the last edition to describe Big Endian; current §7.3 refers there).

So 1-bit OW data in Explicit VR Big Endian holds Big Endian words, and each byte pair has to be swapped before the bits are unpacked, as pydicom already does for 8-bit OW (`be_swap_ow`). pydicom unpacks 1-bit OW Big Endian bytes as they are, because `be_swap_ow` applies only when `bits_allocated // 8 == 1`.

DCMTK 3.7.0 swaps:
- `dcmconv +te` (to Explicit VR Little Endian) writes the swapped bytes;
- `dcm2img` decodes the Big Endian original and the Little Endian copy to the same pixels;
- pydicom decodes the two files differently.

**Steps to reproduce**

```python
import numpy as np
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.uid import ExplicitVRBigEndian, SecondaryCaptureImageStorage, generate_uid

ds = Dataset()
ds.file_meta = FileMetaDataset()
ds.file_meta.TransferSyntaxUID = ExplicitVRBigEndian
ds.file_meta.MediaStorageSOPClassUID = SecondaryCaptureImageStorage
ds.file_meta.MediaStorageSOPInstanceUID = generate_uid()
ds.SOPClassUID = SecondaryCaptureImageStorage
ds.SOPInstanceUID = ds.file_meta.MediaStorageSOPInstanceUID
ds.SamplesPerPixel = 1
ds.PhotometricInterpretation = "MONOCHROME2"
ds.Rows, ds.Columns = 4, 4
ds.NumberOfFrames = 2
ds.BitsAllocated = ds.BitsStored = 1
ds.HighBit = 0
ds.PixelRepresentation = 0
ds.PixelData = bytes([0x01, 0x80, 0x03, 0xC0])   # two Big Endian words
ds["PixelData"].VR = "OW"
ds.save_as("bit_ow_be.dcm", enforce_file_format=True)
print(ds.pixel_array[0].ravel().tolist())
```

```bash
dcmconv +te bit_ow_be.dcm bit_ow_le.dcm   # DCMTK: to Explicit VR Little Endian
dcm2img +opn 1 +F 1 bit_ow_be.dcm         # DCMTK's frame 1 of the original
```

| | Frame 1 |
|---|---|
| pydicom, `bit_ow_be.dcm` | `1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1` |
| pydicom, `bit_ow_le.dcm` (DCMTK's conversion, bytes `80 01 c0 03`) | `0 0 0 0 0 0 0 1 1 0 0 0 0 0 0 0` |
| DCMTK `dcm2img`, either file | `0 0 0 0 0 0 0 1 1 0 0 0 0 0 0 0` |

**Expected:** the Big Endian file decodes as DCMTK decodes it, the same as its Little Endian conversion.

**Related, lower priority:** OB Pixel Data with Bits Allocated over 8 in Explicit VR Big Endian is not allowed. PS3.5 2016b A.3 says such Pixel Data "shall have Value Representation OW" (https://dicom.nema.org/medical/dicom/2016b/output/chtml/part05/chapter_A.html#sect_A.3). For OB, §8.2 Note 1 says the encoding "is unaffected by Little Endian or Big Endian byte ordering". pydicom reads such a value in Big Endian order (bytes `01 02 03 04` as `258, 772`). DCMTK reads it as a byte stream in Little Endian order (`513, 1027`), unchanged by `dcmconv +te`. Being non-conformant input, this may not warrant a change.

**Environment** (`python -m pydicom.env_info`, on main):

```
pydicom      | 3.1.0.dev0
numpy        | 2.5.4
Python       | 3.13.2
platform     | macOS arm64
DCMTK        | 3.7.0 (dcmconv, dcm2img)
```

Also reproduced with pydicom 3.0.2.
