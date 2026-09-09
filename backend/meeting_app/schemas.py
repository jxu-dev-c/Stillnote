"""Validated input boundaries for the local API."""

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class Segment(Input):
    id: str = Field(min_length=1, max_length=100)
    start: float = Field(ge=0)
    end: float = Field(ge=0)
    speaker: str = Field(min_length=1, max_length=100)
    text: str = Field(max_length=50_000)

    @model_validator(mode="after")
    def ordered(self):
        if self.end < self.start:
            raise ValueError("Segment end must follow its start.")
        return self


class MeetingPatch(Input):
    title: str | None = Field(default=None, min_length=1, max_length=240)
    notes: str | None = Field(default=None, max_length=100_000)
    speakers: dict[str, str] | None = None
    segments: list[Segment] | None = Field(default=None, max_length=100_000)

    @model_validator(mode="after")
    def valid_speakers(self):
        if self.speakers is not None and (
            len(self.speakers) > 100
            or any(not k or len(k) > 100 or not v.strip() or len(v) > 100 for k, v in self.speakers.items())
        ):
            raise ValueError("Use nonempty speaker names of at most 100 characters.")
        if self.title is not None and not self.title.strip():
            raise ValueError("A meeting title cannot be blank.")
        return self


class TranscriptionSettings(Input):
    model: Literal["moss-0.9b", "vibevoice-1.5b", "vibevoice-7b"] = "moss-0.9b"
    language: str = Field(default="auto", min_length=2, max_length=20, pattern=r"^[a-zA-Z-]+$")
    speaker_count: int | None = Field(default=None, ge=1, le=20)


class SummarySettings(Input):
    provider: Literal["local", "ollama", "openai-compatible", "anthropic"] = "local"
    model: str = Field(default="", max_length=200)
    base_url: str = Field(default="", max_length=2000)
    api_key: str = Field(default="", max_length=4096)


class SettingsPatch(Input):
    transcription: TranscriptionSettings | None = None
    summary: SummarySettings | None = None


class TranscribeRequest(Input):
    speaker_count: int | None = Field(default=None, ge=1, le=20)
    language: str | None = Field(default=None, min_length=2, max_length=20, pattern=r"^[a-zA-Z-]+$")


class SummaryRequest(Input):
    allow_remote: bool = False


class InstallRequest(Input):
    model: Literal["moss-0.9b", "vibevoice-1.5b", "vibevoice-7b"] = "moss-0.9b"
