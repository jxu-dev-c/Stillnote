"""Validated input boundaries for the local API."""

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, HttpUrl, field_validator, model_validator


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


class ContextLink(Input):
    url: HttpUrl = Field(max_length=4096)
    title: str = Field(default="", max_length=240)

    @model_validator(mode="after")
    def valid_link(self):
        if self.url.username is not None or self.url.password is not None:
            raise ValueError("Use a website link without embedded credentials.")
        self.title = self.title.strip()
        return self


class MeetingPatch(Input):
    title: str | None = Field(default=None, min_length=1, max_length=240)
    notes: str | None = Field(default=None, max_length=100_000)
    context_links: list[ContextLink] | None = Field(default=None, max_length=100)
    summary_include_video_path: bool | None = None
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
        if self.context_links is not None:
            urls = [str(link.url) for link in self.context_links]
            if len(urls) != len(set(urls)):
                raise ValueError("This link is already in the meeting context.")
        return self


class TranscriptionSettings(Input):
    model: Literal["moss-0.9b", "vibevoice-1.5b", "vibevoice-7b"] = "moss-0.9b"
    language: str = Field(default="auto", min_length=2, max_length=20, pattern=r"^[a-zA-Z-]+$")
    speaker_count: int | None = Field(default=None, ge=1, le=20)


class SummarySettings(Input):
    provider: Literal["codex", "claude-code"] = "codex"
    model: str = Field(default="", max_length=200)
    reasoning_effort: Literal["low", "medium", "high"] = "high"

    @field_validator("model")
    @classmethod
    def valid_model(cls, value: str):
        if any(ord(char) < 32 for char in value):
            raise ValueError("Use a model name without control characters.")
        return value.strip()


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


class RecordingRequest(Input):
    title: str = Field(default="Untitled meeting", min_length=1, max_length=200)
    language: str = Field(default="auto", min_length=2, max_length=20, pattern=r"^[a-zA-Z-]+$")
    speaker_count: int | None = Field(default=None, ge=1, le=20)
    microphone_id: str = Field(default="", max_length=512)
    display_id: int | None = Field(default=None, gt=0, le=4294967295)
    system_audio: bool = True
    screen_video: bool = False

    @field_validator("title")
    @classmethod
    def recording_title(cls, value):
        if not value.strip():
            raise ValueError("Enter a meeting title.")
        return value.strip()
