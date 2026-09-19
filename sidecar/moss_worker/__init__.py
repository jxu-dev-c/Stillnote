"""MOSS 0.9B inference for Stillnote.

This package is the only part of Stillnote that is not Swift: the MOSS checkpoint runs
through the pinned MLX Audio runtime, which has no Swift equivalent. The Swift app owns
audio capture, decoding, storage, and transcript parsing; this worker receives decoded
16 kHz mono float32 samples and returns MOSS's raw text.
"""
