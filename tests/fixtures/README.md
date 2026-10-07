# Synthetic contract fixtures

`images.json` contains base64-encoded, synthetic 3 × 2 images. The basic images
are red; animation frames alternate red and blue. Additional fixtures exercise
progressive/grayscale/CMYK JPEG, PNG alpha/palette modes, and lossless WebP.
They were generated with Pillow 12.3.0 before retiring the Python runtime.
No account content or credentials are included.

`contracts.json` records the Python prototype's fetch metadata, upload result,
and post result using these fixtures and mock HTTP responses. It was generated
from the implementation in commit `aaa39e4`, with synthetic IDs and credentials.
The cross-language MCP client tests compare native Racket results against these
records. This retains the original observable contracts without maintaining a
second production implementation. No Pillow installation is needed to run tests.
