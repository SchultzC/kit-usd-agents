## Copyright (c) 2025, NVIDIA CORPORATION.  All rights reserved.
##
## NVIDIA CORPORATION and its licensors retain all intellectual property
## and proprietary rights in and to this software, related documentation
## and any modifications thereto.  Any use, reproduction, disclosure or
## distribution of this software and related documentation without an express
## license agreement from NVIDIA CORPORATION is strictly prohibited.
##

from importlib import import_module
from typing import Any, Callable, Optional

from langchain_core.messages import SystemMessage
from langchain_core.prompt_values import ChatPromptValue
from langchain_core.runnables.base import RunnableLambda
from lc_agent import RunnableNetwork, RunnableNode
from lc_agent_rag_modifiers import BaseRagModifier
from lc_agent.utils.pydantic import BaseModel
from pydantic import Field, model_serializer


class ModuleFunctionsAppender(BaseModel, RunnableLambda):
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


class ModuleFunctionsSystemModifier(BaseRagModifier):
    """
    Injects a system message enumerating first-level public functions of a helper module
    (with docstrings, without source) into the target LLM node.

    It reuses the RAG injection lifecycle (leaf-node detection, parent lookup) via BaseRagModifier,
    but does not call any retriever.
    """

    def __init__(self, module_name: str, title: Optional[str] = None) -> None:
        super().__init__()
        self._module_name = module_name
        self._title = title or "The following functions are available for you to use in the module: {module}"

        # Precompute once to avoid repeated imports/inspection per invoke
        self._content = self._build_content()

    def _build_content(self) -> str:
        # Import here to avoid circular dependency
        from ..nodes.usd_meta_functions_parser import extract_module_functions
        
        try:
            mod = import_module(self._module_name)
        except Exception as e:
            return f"Failed to import module '{self._module_name}': {e}"

        signatures = extract_module_functions(mod)
        header = self._title.replace("{module}", self._module_name)
        return f"{header}\n\n{signatures}" if signatures else header

    def _inject_rag(self, network: RunnableNetwork, node: RunnableNode, question: str):
        # Avoid duplicate injection per node
        injected_key = "module_functions_system_injected"
        if node.metadata.get(injected_key):
            return

        node.metadata[injected_key] = True

        appender = ModuleFunctionsAppender(content=self._content)
        # Put the module functions system message at the beginning
        node.inputs.insert(0, appender)



