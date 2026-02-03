## Copyright (c) 2025, NVIDIA CORPORATION.  All rights reserved.
##
## NVIDIA CORPORATION and its licensors retain all intellectual property
## and proprietary rights in and to this software, related documentation
## and any modifications thereto.  Any use, reproduction, disclosure or
## distribution of this software and related documentation without an express
## license agreement from NVIDIA CORPORATION is strictly prohibited.
##

from typing import Any, Callable, Optional

from langchain_core.messages import SystemMessage
from langchain_core.prompt_values import ChatPromptValue
from langchain_core.runnables.base import RunnableLambda
from lc_agent import RunnableNetwork, RunnableNode
from lc_agent_rag_modifiers import BaseRagModifier
from lc_agent.utils.pydantic import BaseModel
from pydantic import Field, model_serializer


class SystemMessageAppender(BaseModel, RunnableLambda):
    """
    Runnable step that appends a SystemMessage with provided content
    to the current input.
    """

    content: str = Field(..., description="System message body to append")
    # Keep parity with other RunnableLambda models: include fields that must be ignored in serialization
    type: str = "system"
    func: Optional[Callable] = None
    afunc: Optional[Any] = None
    name: Optional[str] = None

    def __init__(self, content: str):
        BaseModel.__init__(self, content=content)
        # Use async executor to align with ainvoke path in networks
        RunnableLambda.__init__(self, func=self._aexecute)

    def _iter(self, *args, **kwargs):
        kwargs["exclude"] = (kwargs.get("exclude", None) or set()) | {"func", "afunc"}
        yield from super()._iter(*args, **kwargs)

    @model_serializer
    def serialize_model(self) -> dict:
        result = {}
        for field_name, field_value in self:
            if field_name not in ["func", "afunc"]:
                result[field_name] = field_value
        return result

    async def _aexecute(self, input, **kwargs):
        message = SystemMessage(content=self.content)

        # Append as in retreiver_utils._append_message_to_input
        if isinstance(input, ChatPromptValue):
            input.messages.append(message)
            return input
        elif isinstance(input, list):
            input.append(message)
            return input
        elif isinstance(input, dict):
            return [input, message]
        else:
            return ChatPromptValue(messages=[message])


class SystemMessageModifier(BaseRagModifier):
    """
    Injects a custom system message into the target LLM node.

    This modifier allows you to inject any system message into a network node,
    providing a flexible way to add context or instructions to the LLM.

    It reuses the RAG injection lifecycle (leaf-node detection, parent lookup) via BaseRagModifier,
    but does not call any retriever.
    
    Args:
        system_message: The system message content to inject
        metadata_key: Optional unique key for preventing duplicate injection (defaults to 'system_message_injected')
    """

    def __init__(self, system_message: str, metadata_key: Optional[str] = None) -> None:
        super().__init__()
        self._system_message = system_message
        self._metadata_key = metadata_key or "system_message_injected"

    def _inject_rag(self, network: RunnableNetwork, node: RunnableNode, question: str):
        # Avoid duplicate injection per node
        if node.metadata.get(self._metadata_key):
            return

        node.metadata[self._metadata_key] = True

        appender = SystemMessageAppender(content=self._system_message)
        # Put the system message at the beginning
        node.inputs.insert(0, appender)
