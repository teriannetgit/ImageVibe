# ImageVibe

A native macOS app that turns a text prompt into an image with the Bonsai Image 4B
ternary model, running entirely on your Mac. On-device and offline after a one-time,
hash-verified model download. No account, no server, no Python.

## What it does

- Type a prompt and generate. Each saved image keeps its prompt, seed and settings in
  the film roll, so you can reuse them, vary the seed and compare results.
- Controls the model accepts: prompt (1–2,000 characters), width and height (multiples
  of 16 from 256 to 1024), steps (1–8, tuned for 4), seed and full-precision decode.
  There is no guidance scale, negative prompt or image-to-image.
- The model reads the first 512 tokens of the prompt. The app warns when a prompt is
  truncated; generation continues.
- A generation can't be stopped once it starts.
- Saved PNGs and their JSON settings records live in the app's Application Support
  folder. Exported PNGs don't include the settings record.

## Privacy

- Images and prompts stay on your Mac. The app has no analytics and no server.
- The only network use is the model download from Hugging Face
  (`prism-ml/bonsai-image-ternary-4B-mlx-2bit`, about 3.7 GB), pinned to a commit and
  checked file by file against SHA-256 hashes.
- App Sandbox and Hardened Runtime are on. The entitlements are the network client
  (model download only) and read/write for files you choose in Save.
- Every PNG carries the IPTC `trainedAlgorithmicMedia` tag in XMP, the machine-readable
  label for AI-generated images.

## Requirements

- An Apple silicon Mac running macOS 27.
- Memory use is high, and 8 GB and 16 GB Macs aren't supported. Measured peak on a
  24 GB M4 Pro: Draft 512×512 6.9 GB, Final 1024×1024 13.3 GB, Final with full-precision
  decode 17.1 GB.

## Building

You need Xcode 27 with the Metal Toolchain component (for MLX's shaders) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
# 1. Download the image decoder the app bundles (56 MB) and check it
curl -L -o Resources/vae.safetensors \
  https://github.com/duration-ai/bonsai-image-ios/releases/download/v0.1.0/vae.safetensors
shasum -a 256 Resources/vae.safetensors
# expected: b8bc0f15841c4df07467f4122b382360c913dd86125788ed2f2b83370b383398

# 2. Generate the Xcode project and open it
xcodegen generate
open ImageVibe.xcodeproj
```

Then choose **Product › Run**. The app is signed to run locally, so builds run on the
Mac that made them. To distribute it, set your own bundle ID and signing in
`project.yml`.

On first launch the app offers to download the model.

## Credits

- Created using Bonsai Image by Prism ML. The model is Apache-2.0, built from FLUX.2
  [klein] 4B by Black Forest Labs and Qwen3-4B by Alibaba Cloud.
- Engine: the Apache-2.0 [Duration AI Swift port](https://github.com/duration-ai/bonsai-image-ios)
  of Bonsai, using MLX Swift and Hugging Face's Swift tokenizers. Not official PrismML
  source.
- ImageVibe isn't affiliated with or endorsed by any of these projects. See `NOTICE`
  for attributions; full third-party licences are in `Resources/Acknowledgements.json`
  and shown in the app's About window.

## License

Apache License 2.0. See `LICENSE`.
