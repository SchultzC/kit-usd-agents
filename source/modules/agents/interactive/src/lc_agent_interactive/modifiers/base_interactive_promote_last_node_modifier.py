## Copyright (c) 2025, NVIDIA CORPORATION.  All rights reserved.
##
## NVIDIA CORPORATION and its licensors retain all intellectual property
## and proprietary rights in and to this software, related documentation
## and any modifications thereto.  Any use, reproduction, disclosure or
## distribution of this software and related documentation without an express
## license agreement from NVIDIA CORPORATION is strictly prohibited.
##

from langchain_core.messages import AIMessage, HumanMessage
from lc_agent import NetworkModifier, NetworkNode, RunnableNetwork

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ..nodes.base_interactive_network_node import BaseInteractiveNetworkNode


class BaseInteractivePromoteLastNodeModifier(NetworkModifier):
    """
    Promote the last executed leaf node's output to the network output.

    Behavior:
    - If running in a multi-agent context and the leaf node contains
      code-interpreter metadata (code + result or error), copy the relevant
      fields to the network metadata and format the network output so the
      user can see the executed code and its result/error.
    - Otherwise, forward the leaf node's AIMessage content as the network output.

    Place this modifier alongside the interactive pipeline so it runs after
    the leaf node finishes, typically near code extraction/patching and the
    interpreter modifiers.
    """

    async def on_end_invoke_async(self, network: "BaseInteractiveNetworkNode"):
        """Finalize network output using the last leaf node.

        Args:
            network: The interactive network node whose leaf outputs are inspected.

        Notes:
            - If there is not exactly one leaf, the method returns without changes.
            - In multi-agent runs with interpreter metadata, the method surfaces
              the interpreter code and either the result or the error, and emits
              a NODE_INVOKED event for the network.
        """
        leafs = network.get_leaf_nodes()
        if len(leafs) != 1:
            return

        node = leafs[0]

        if isinstance(network, NetworkNode):
            metadata = node.metadata
            interpreter_code = metadata.get("interpreter_code")
            interpreter_error = metadata.get("interpreter_error")
            interpreter_result = metadata.get("interpreter_result")

            is_multi_agent = ("tool_call_id" in metadata) or ("tool_call_name" in network.metadata)
            if interpreter_code and interpreter_error and is_multi_agent:
                network.metadata["interpreter_code"] = interpreter_code
                network.metadata["interpreter_error"] = interpreter_error
                network.outputs = AIMessage(
                    content=f"```python\n{interpreter_code}\n```\n\n"
                    f"Executed with error:\n```{interpreter_error}\n```\n"
                )
                network._event_callback(
                    RunnableNetwork.Event.NODE_INVOKED,
                    {"node": network, "network": network},
                )

                return
            elif interpreter_code and interpreter_result and is_multi_agent:
                network.metadata["interpreter_code"] = interpreter_code
                network.metadata["interpreter_result"] = interpreter_result
                network.outputs = AIMessage(
                    content=f"```python\n{interpreter_code}\n```\nOutput:```{interpreter_result}\n```"
                )
                network._event_callback(
                    RunnableNetwork.Event.NODE_INVOKED,
                    {"node": network, "network": network},
                )

                return

        # Use the output of the last node as the output of the network
        network.outputs = AIMessage(content=node.outputs.content)
        network._event_callback(
            RunnableNetwork.Event.NODE_INVOKED,
            {"node": network, "network": network},
        )
