## Copyright (c) 2025, NVIDIA CORPORATION.  All rights reserved.
##
## NVIDIA CORPORATION and its licensors retain all intellectual property
## and proprietary rights in and to this software, related documentation
## and any modifications thereto.  Any use, reproduction, disclosure or
## distribution of this software and related documentation without an express
## license agreement from NVIDIA CORPORATION is strictly prohibited.
##

from typing import List, Optional

from lc_agent import NetworkNode
from lc_agent_rag_modifiers import SystemRagModifier
from lc_agent_usd.modifiers.code_extractor_modifier import CodeExtractorModifier
from lc_agent_usd.modifiers.code_interpreter_modifier import CodeInterpreterModifier
from lc_agent_usd.modifiers.code_patcher_modifier import CodePatcherModifier

from ..modifiers.module_functions_system_modifier import ModuleFunctionsSystemModifier
from ..modifiers.base_interactive_promote_last_node_modifier import BaseInteractivePromoteLastNodeModifier
from ..modifiers.system_message_modifier import SystemMessageModifier


class InteractiveCodePatcherModifier(CodePatcherModifier):
    def __init__(self, prepend_code: str = ""):
        super().__init__()
        self._prepend_code = prepend_code

    def _patch_code(self, code):
        return super()._patch_code(self._prepend_code + code)


class BaseInteractiveNetworkNode(NetworkNode):
    """
    Base interactive network node that:
    - Optionally inserts a custom system message if provided
    - Inserts a system message containing first-level public functions from a helper module
    - Injects one or more RAG retrievers as system messages

    Subclasses should provide `default_node` and their own default parameters, but behavior is generic.
    """

    default_node: str = ""
    prepend_code: str = ""

    def __init__(
        self,
        helper_module: str,
        retriever_names: Optional[List[str]] = None,
        enable_code_interpreter: bool = True,
        system_message: Optional[str] = None,
        **kwargs,
    ):
        super().__init__(**kwargs)

        # Add custom system message if provided
        if system_message:
            self.add_modifier(SystemMessageModifier(system_message=system_message))

        # Add helper-module system message injector (signatures + docstrings)
        self.add_modifier(ModuleFunctionsSystemModifier(module_name=helper_module))

        # Read optional RAG limits from metadata
        rag_top_k = self.find_metadata("rag_top_k")
        rag_max_tokens = self.find_metadata("rag_max_tokens")

        # Add multiple standard system RAGs, if any
        for name in retriever_names or []:
            if not name:
                continue
            self.add_modifier(
                SystemRagModifier(
                    retriever_name=name,
                    top_k=rag_top_k,
                    max_tokens=rag_max_tokens,
                )
            )

        # Optional CodeInterpreterModifier (reused exactly from USD agent)
        if enable_code_interpreter:
            self.add_modifier(BaseInteractivePromoteLastNodeModifier())
            self.add_modifier(CodeExtractorModifier())
            self.add_modifier(InteractiveCodePatcherModifier(prepend_code=self.prepend_code))
            self.add_modifier(CodeInterpreterModifier())
