---
summary: Draft upstream issue for pydicom. pixel_array(ds, index=i) fails or reads short for 1-bit multi-frame native Pixel Data when a frame doesn't start on a byte boundary; the all-frames path is right. Found in M4; verified on pydicom 3.0.2 and main. Not yet posted.
read_when:
  - posting or following up upstream pydicom issues
  - changing how dartdicom's fixtures or goldens decode 1-bit data with pydicom
---

# Draft: pydicom per-frame decode of non-byte-aligned 1-bit frames

**Target:** `pydicom/pydicom`, template *Pixel Data issue* (`pixel_issue.md`, label `pixel-data`).

**Status:** not posted; it needs review before it goes out under a maintainer's account. Lifecycle (docs/issues is a staging shelf): post it, then delete this file and leave the issue number in the commit.

**Checked before posting (2026-10-18):**
- **Verified:** reproduced on pydicom 3.0.2 and on main at `a6374203fe` (2026-10-14), with numpy 2.5.4.
- **Searched:** keyword searches of pydicom's issues found no match: "bits allocated 1 frame index", "1-bit pixel_array index ValueError reshape", "single bit frame", "BitsAllocated 1 multi-frame". Keyword search is not exhaustive.
- **Not verified:** pydicom versions before 3.0, and whether `iter_pixels` or `Decoder.iter_array` share the fault.

**Effect on dartdicom:** none in the shipped code. The LUT goldens decode every frame at once and split them (`fixtures/src/dartdicom_fixtures/lut.py`), and `fixtures/data/synthetic/seg_1bit_unaligned.dcm` triggers the bug if a golden ever uses the per-frame path.

---

## Issue text

**Title:** `pixel_array(ds, index=i)` fails for 1-bit Pixel Data when frame *i* doesn't start on a byte boundary

**Describe the issue**

For native (uncompressed) Pixel Data with Bits Allocated 1, frames are not padded: when Rows × Columns × Samples per Pixel is not a multiple of 8, frame *i* > 0 starts in the middle of a byte. PS3.5 §8.1.1 Note 2: "a frame other than the first frame may start in the middle of a byte or word" (DICOM PS3.5 2026d, https://dicom.nema.org/medical/dicom/current/output/chtml/part05/chapter_8.html#sect_8.1.1).

Decoding all frames (`ds.pixel_array`) handles this correctly. Decoding a single frame (`pixel_array(ds, index=i)`) reads one byte too few whenever the frame's bit offset plus its length runs past the bytes it reads. The reshape then fails. The per-frame path appears to read `ceil(length_bytes)` bytes starting at `floor(index * length_bytes)` (`pixels/decoders/base.py`, the `bits_allocated == 1` branch of the native decoder), which is one byte short for such frames.

**Steps to reproduce**

```python
import numpy as np
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.pixels import pack_bits, pixel_array
from pydicom.uid import ExplicitVRLittleEndian

ds = Dataset()
ds.file_meta = FileMetaDataset()
ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
ds.SamplesPerPixel = 1
ds.PhotometricInterpretation = "MONOCHROME2"
ds.Rows, ds.Columns = 3, 5          # 15 bits per frame
ds.NumberOfFrames = 3
ds.BitsAllocated = ds.BitsStored = 1
ds.HighBit = 0
ds.PixelRepresentation = 0
ds.PixelData = pack_bits((np.arange(45) % 3 == 0).astype(np.uint8), pad=True)
ds["PixelData"].VR = "OB"

whole = ds.pixel_array              # correct: shape (3, 3, 5)
for i in range(3):
    print(i, pixel_array(ds, index=i).shape)
```

Output:

```
0 (3, 5)
ValueError: cannot reshape array of size 9 into shape (3,5)     # index=1
ValueError: cannot reshape array of size 10 into shape (3,5)    # index=2
```

**Expected:** `pixel_array(ds, index=i)` equals `ds.pixel_array[i]` for every frame.

**Environment** (`python -m pydicom.env_info`, on main):

```
pydicom      | 3.1.0.dev0
numpy        | 2.5.4
Python       | 3.13.2
platform     | macOS arm64
```

Also reproduced with pydicom 3.0.2.
