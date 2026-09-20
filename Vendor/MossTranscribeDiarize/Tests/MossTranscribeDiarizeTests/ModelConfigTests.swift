import XCTest
@testable import MossTranscribeDiarize

final class ModelConfigTests: XCTestCase {
    func testDecodeQuantizedConfig() throws {
        let json = """
        {
          "model_type": "moss_transcribe_diarize",
          "text_config": {
            "model_type": "qwen3",
            "vocab_size": 151936,
            "hidden_size": 1024,
            "intermediate_size": 3072,
            "num_hidden_layers": 28,
            "num_attention_heads": 16,
            "num_key_value_heads": 8,
            "head_dim": 128
          },
          "audio_config": {
            "model_type": "whisper",
            "num_mel_bins": 80,
            "d_model": 1024,
            "encoder_layers": 24,
            "encoder_attention_heads": 16,
            "encoder_ffn_dim": 4096,
            "max_source_positions": 1500
          },
          "audio_token_id": 151671,
          "audio_merge_size": 4,
          "adaptor_input_dim": 4096,
          "tie_word_embeddings": true,
          "quantization": {
            "bits": 8,
            "group_size": 64,
            "mode": "affine",
            "scope": "text_backbone_only",
            "excluded_prefixes": ["model.whisper_encoder", "model.vq_adaptor"]
          }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(ModelConfig.self, from: json)
        XCTAssertEqual(config.modelType, "moss_transcribe_diarize")
        XCTAssertEqual(config.textConfig.numHiddenLayers, 28)
        XCTAssertEqual(config.audioConfig.dModel, 1024)
        XCTAssertEqual(config.adaptorInputDim, 4096)
        XCTAssertEqual(config.quantization?.bits, 8)
        XCTAssertEqual(config.quantization?.groupSize, 64)
        XCTAssertTrue(config.quantization?.shouldExclude(path: "model.whisper_encoder.conv1") ?? false)
        XCTAssertFalse(config.quantization?.shouldExclude(path: "model.language_model.layers.0") ?? true)
    }

    func testModelVariantCatalog() {
        XCTAssertTrue(ModelVariant.int8.repositoryID.contains("8bit"))
        XCTAssertTrue(ModelVariant.int4.repositoryID.contains("4bit"))
        XCTAssertFalse(ModelVariant.fullPrecision.repositoryID.contains("bit"))
    }
}
