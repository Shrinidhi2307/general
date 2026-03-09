from enum import Enum

from pydantic import BaseModel


class ThreatLevel(str, Enum):
    critical = "critical"
    high = "high"
    medium = "medium"
    low = "low"
    info = "info"


class Finding(BaseModel):
    threat_level: ThreatLevel
    description: str
    affected_ips: list[str]
    log_source: str
    sample_lines: list[str]
    recommended_actions: list[str]


class AnalysisResponse(BaseModel):
    findings: list[Finding]
    summary: str
