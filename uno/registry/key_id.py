###############################################################################
# Copyright 2020-2024 Andrea Sorbini
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
###############################################################################
from enum import Enum
import yaml

from .cell import Cell
from .uvn import Uvn
from .particle import Particle


class KeyId:
  class Type(Enum):
    ROOT = 0
    CELL = 1
    PARTICLE = 2

  def __init__(self, key_type: "KeyId.Type", owner: str, target: str) -> None:
    self.key_type = key_type
    if not isinstance(self.key_type, KeyId.Type):
      raise RuntimeError("invalid key type", repr(self.key_type))
    self.owner = owner
    self.target = target

  def __eq__(self, other):
    if not isinstance(other, KeyId):
      return False
    return (
      self.owner == other.owner and self.key_type == other.key_type and self.target == other.target
    )

  def __hash__(self) -> int:
    return hash((self.key_type, self.owner, self.target))

  def __str__(self) -> str:
    return f"{self.key_type.name.lower()}/{self.owner}/{self.target}"

  def __repr__(self) -> str:
    return f"KeyId(KeyId.Type.{self.key_type.name}, {repr(self.owner)}, {repr(self.target)})"

  def query(
    self, key_type: str | None = None, owner: str | None = None, target: str | None = None
  ) -> bool:
    return (
      (key_type is None or key_type == self.key_type)
      and (owner is None or owner == self.owner)
      and (target is None or target == self.target)
    )

  def key_description(self) -> str:
    import json

    return json.dumps(self.serialize())

  def serialize(self) -> dict:
    return {
      "key_type": self.key_type.name,
      "owner": self.owner,
      "target": self.target,
    }

  @staticmethod
  def deserialize(serialized: dict) -> "KeyId":
    return KeyId(
      key_type=KeyId.Type[serialized["key_type"]],
      owner=serialized["owner"],
      target=serialized["target"],
    )

  @staticmethod
  def parse_key_description(key_desc: str) -> "KeyId":
    key_info_start = key_desc.find("(")
    if key_info_start < 0:
      raise ValueError("invalid key description", key_desc)
    # skip "("
    key_info_start += 1
    key_info_end = key_desc.rfind(")")
    if key_info_end < 0 or key_info_start >= key_info_end:
      raise ValueError("invalid key description", key_desc)
    try:
      key_info = yaml.safe_load(key_desc[key_info_start:key_info_end])
      return KeyId.deserialize(key_info)
    except Exception:
      raise ValueError("failed to parse key description", key_desc)

  @staticmethod
  def from_uvn(id: Uvn | Cell | Particle) -> "KeyId":
    if isinstance(id, Uvn):
      return KeyId(key_type=KeyId.Type.ROOT, owner=id.owner.email, target=id.name)
    elif isinstance(id, Cell):
      return KeyId(key_type=KeyId.Type.CELL, owner=id.owner.email, target=id.name)
    elif isinstance(id, Particle):
      return KeyId(key_type=KeyId.Type.PARTICLE, owner=id.owner.email, target=id.name)
    else:
      raise ValueError(id)
