## Copyright (c) 2025, NVIDIA CORPORATION.  All rights reserved.
##
## NVIDIA CORPORATION and its licensors retain all intellectual property
## and proprietary rights in and to this software, related documentation
## and any modifications thereto.  Any use, reproduction, disclosure or
## distribution of this software and related documentation without an express
## license agreement from NVIDIA CORPORATION is strictly prohibited.
##

from typing import Union
from typing import get_origin, get_args
import ast
import inspect
import types


def extract_function_signatures(filename: str) -> str:
    with open(filename, "r") as file:
        code = file.read()

    # Parse the code into an AST
    parsed_code = ast.parse(code)

    # Extract the function definitions (both regular and async)
    functions = [node for node in parsed_code.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))]

    # Generate the desired output
    output = ""
    for func in functions:
        func_name = func.name
        
        # Format arguments with type annotations and defaults
        args = []
        
        # Regular positional arguments
        num_args = len(func.args.args)
        num_defaults = len(func.args.defaults)
        num_args_without_defaults = num_args - num_defaults
        
        for i, arg in enumerate(func.args.args):
            # Build parameter string with type annotation
            param_str = f"{arg.arg}: {ast.unparse(arg.annotation)}" if arg.annotation else arg.arg
            
            # Add default value if this parameter has one
            if i >= num_args_without_defaults:
                default_index = i - num_args_without_defaults
                default_value = ast.unparse(func.args.defaults[default_index])
                param_str += f" = {default_value}"
            
            args.append(param_str)
        
        # *args
        if func.args.vararg:
            vararg_str = f"*{func.args.vararg.arg}"
            if func.args.vararg.annotation:
                vararg_str = f"*{func.args.vararg.arg}: {ast.unparse(func.args.vararg.annotation)}"
            args.append(vararg_str)
        
        # Keyword-only arguments
        if func.args.kwonlyargs:
            # If there's no vararg, we need to add a bare * to indicate keyword-only args
            if not func.args.vararg:
                args.append("*")
            
            for i, kwarg in enumerate(func.args.kwonlyargs):
                kwarg_str = f"{kwarg.arg}: {ast.unparse(kwarg.annotation)}" if kwarg.annotation else kwarg.arg
                
                # Add default if present (kw_defaults can contain None)
                if i < len(func.args.kw_defaults) and func.args.kw_defaults[i] is not None:
                    default_value = ast.unparse(func.args.kw_defaults[i])
                    kwarg_str += f" = {default_value}"
                
                args.append(kwarg_str)
        
        # **kwargs
        if func.args.kwarg:
            kwarg_str = f"**{func.args.kwarg.arg}"
            if func.args.kwarg.annotation:
                kwarg_str = f"**{func.args.kwarg.arg}: {ast.unparse(func.args.kwarg.annotation)}"
            args.append(kwarg_str)
        
        return_annotation = ast.unparse(func.returns) if func.returns else "None"
        docstring = ast.get_docstring(func)

        # Check if it's an async function
        is_async = isinstance(func, ast.AsyncFunctionDef)
        func_def = "async def" if is_async else "def"

        output += f"{func_def} {func_name}({', '.join(args)}) -> {return_annotation}:\n"
        if docstring:
            output += f'    """{docstring}"""\n'
        output += "    ...\n\n"

    return output.strip()


def format_type_annotation(annotation) -> str:
    """Format a type annotation into a clean string representation.

    Args:
        annotation: A type annotation object

    Returns:
        str: A clean string representation of the type
    """
    if annotation == inspect.Parameter.empty:
        return "Any"

    # Handle Union types
    origin = get_origin(annotation)
    if origin is not None:
        args = get_args(annotation)
        # Format each argument
        formatted_args = [format_type_annotation(arg) for arg in args]
        # Special case for Union - use | for Python 3.10+ syntax
        if origin == Union:
            return " | ".join(formatted_args)
        # For other types (List, Dict, etc)
        return f"{origin.__name__}[{', '.join(formatted_args)}]"

    # Handle simple types
    if hasattr(annotation, "__name__"):
        # Use __module__ and __qualname__ to get the full type name.
        module = getattr(annotation, "__module__", "")
        qualname = getattr(annotation, "__qualname__", annotation.__name__)
        if module and module != "builtins":
            full_name = f"{module}.{qualname}"
        else:
            full_name = qualname

        if full_name.startswith("typing."):
            full_name = full_name[len("typing.") :]

        if full_name.startswith("pxr."):
            full_name = full_name[len("pxr.") :]

        return full_name

    # Fallback for any other case
    return str(annotation)


def extract_module_functions(module) -> str:
    """Extract function signatures from a module object.

    Args:
        module: A Python module object to extract functions from.

    Returns:
        str: A string containing all function signatures with their docstrings,
             but without function bodies.

    Example:
        >>> import usdcode
        >>> signatures = extract_module_functions(usdcode)
        >>> print(signatures)
        def function1(arg1: str, arg2: int) -> None:
            '''Function docstring'''
            ...
    """
    output = ""

    # Get all module attributes
    for name, obj in inspect.getmembers(module):
        # Skip if it's not a function or is a builtin/special method
        if not isinstance(obj, types.FunctionType) or name.startswith("_"):
            continue

        # Get function signature
        sig = inspect.signature(obj)

        # Format parameters with their type annotations
        params = []
        for param_name, param in sig.parameters.items():
            annotation_str = format_type_annotation(param.annotation)
            
            # Handle different parameter kinds
            if param.kind == inspect.Parameter.VAR_POSITIONAL:
                # *args
                param_str = f"*{param_name}: {annotation_str}"
            elif param.kind == inspect.Parameter.VAR_KEYWORD:
                # **kwargs
                param_str = f"**{param_name}: {annotation_str}"
            else:
                # Regular or keyword-only parameter
                param_str = f"{param_name}: {annotation_str}"
                
                # Add default value if present
                if param.default != inspect.Parameter.empty:
                    param_str += f" = {repr(param.default)}"
            
            params.append(param_str)

        # Get return type annotation
        return_annotation_str = format_type_annotation(sig.return_annotation)

        # Check if the function is async
        is_async = inspect.iscoroutinefunction(obj)
        func_def = "async def" if is_async else "def"

        # Format function definition
        output += f"{func_def} {name}({', '.join(params)}) -> {return_annotation_str}:\n"

        # Add docstring if it exists
        if obj.__doc__:
            output += f'    """{obj.__doc__}"""\n'

        output += "\n"

    return output.strip()
