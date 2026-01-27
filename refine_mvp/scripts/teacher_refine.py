from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

import numpy as np


class TeacherRefiner:
    def refine(self, X: np.ndarray, mask: np.ndarray) -> np.ndarray:
        """
        Args:
            X: [T,3] float32
            mask: [T] float32 (1=real token, 0=pad)
        Returns:
            Y: [T,3] float32
        """
        raise NotImplementedError

    def close(self) -> None:
        pass


class IdentityTeacher(TeacherRefiner):
    def refine(self, X: np.ndarray, mask: np.ndarray) -> np.ndarray:
        _ = mask
        return np.array(X, dtype=np.float32, copy=True)


@dataclass(frozen=True)
class DeepWritingSubprocessConfig:
    python: str = "python3"
    infer_script: Path = Path("deepwriting_infer_server.py")
    deepwriting_root: Path = Path("deepwriting-teacher")
    model_save_dir: Path = Path("runs")
    model_id: str = ""
    checkpoint_id: str | None = None
    protocol_prefix: str = "@@DWJSON@@"


class DeepWritingSubprocessTeacher(TeacherRefiner):
    """
    Phase 1 / 1.5 (plan): run DeepWriting deterministically as an offline teacher.

    This implementation uses a persistent python subprocess so TF graph + weights are loaded once.
    """

    def __init__(self, cfg: DeepWritingSubprocessConfig):
        if not cfg.model_id:
            raise ValueError("DeepWritingSubprocessConfig.model_id is required")
        self.cfg = cfg
        self._proc: subprocess.Popen[str] | None = None
        self._start()

    def _start(self) -> None:
        if self._proc is not None and self._proc.poll() is None:
            return

        cmd: list[str] = [
            self.cfg.python,
            "-u",
            str(self.cfg.infer_script),
            "--deepwriting-root",
            str(self.cfg.deepwriting_root),
            "--model-save-dir",
            str(self.cfg.model_save_dir),
            "--model-id",
            self.cfg.model_id,
            "--protocol-prefix",
            self.cfg.protocol_prefix,
        ]
        if self.cfg.checkpoint_id is not None:
            cmd += ["--checkpoint-id", self.cfg.checkpoint_id]

        env = dict(os.environ)
        env["PYTHONUNBUFFERED"] = "1"
        env.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

        # stdout is the protocol channel; stderr inherits so logs won't deadlock the pipe.
        self._proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=None,
            text=True,
            bufsize=1,
            env=env,
        )
        if self._proc.stdin is None or self._proc.stdout is None:
            raise RuntimeError("Failed to open stdin/stdout for DeepWriting subprocess")

    def refine(self, X: np.ndarray, mask: np.ndarray) -> np.ndarray:
        if X.ndim != 2 or X.shape[1] != 3:
            raise ValueError(f"Expected X shape [T,3], got {X.shape}")
        if mask.ndim != 1 or mask.shape[0] != X.shape[0]:
            raise ValueError(f"Expected mask shape [T], got {mask.shape} for X {X.shape}")

        self._start()
        assert self._proc is not None
        assert self._proc.stdin is not None
        assert self._proc.stdout is not None

        payload = json.dumps({"X": X.tolist(), "mask": mask.tolist()}, separators=(",", ":"))
        self._proc.stdin.write(payload + "\n")
        self._proc.stdin.flush()

        prefix = self.cfg.protocol_prefix
        while True:
            line = self._proc.stdout.readline()
            if line == "":
                code = self._proc.poll()
                raise RuntimeError(f"DeepWriting subprocess exited unexpectedly (code={code})")
            line = line.rstrip("\n")
            if not line.startswith(prefix):
                continue
            obj = json.loads(line[len(prefix) :])
            Y = np.asarray(obj["Y"], dtype=np.float32)
            break

        if Y.shape != X.shape:
            raise ValueError(f"Teacher output shape {Y.shape} != input shape {X.shape}")
        return Y

    def close(self) -> None:
        if self._proc is None:
            return
        try:
            if self._proc.stdin is not None:
                self._proc.stdin.close()
        except Exception:
            pass
        try:
            self._proc.terminate()
        except Exception:
            pass
        try:
            self._proc.wait(timeout=5)
        except Exception:
            pass
        self._proc = None

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass
