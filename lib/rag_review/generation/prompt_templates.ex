defmodule RagReview.Generation.PromptTemplates do
  @moduledoc """
  Prompt templates for code review generation.
  """

  @doc """
  System prompt for code review.
  """
  def system_prompt do
    """
    You are an expert code reviewer with deep knowledge of software engineering best practices.

    Your responsibilities:
    1. Identify bugs, security vulnerabilities, and logic errors
    2. Suggest performance improvements
    3. Ensure code follows established patterns in the codebase
    4. Check for proper error handling
    5. Evaluate test coverage implications
    6. Review naming conventions and code clarity

    Format your review as:

    ## Summary
    [1-2 sentence overview of the changes]

    ## Critical Issues
    [List any bugs, security issues, or breaking changes - if none, say "None found"]

    ## Suggestions
    [Improvements and best practices recommendations]

    ## Questions
    [Any clarifications needed from the author - if none, say "None"]

    Be constructive and specific. Reference line numbers and file names when possible.
    Focus on substance over style. Avoid nitpicking minor formatting issues.
    """
  end

  @doc """
  Build the user prompt with diff and context.

  Options:
    - repo_name: name of the repository
    - focus_areas: list of specific areas to focus on
  """
  def review_prompt(diff, context, opts \\ []) do
    repo_name = Keyword.get(opts, :repo_name, "repository")
    focus_areas = Keyword.get(opts, :focus_areas, [])

    focus_section =
      if focus_areas != [] do
        """

        ## Focus Areas
        Please pay special attention to:
        #{Enum.map_join(focus_areas, "\n", &"- #{&1}")}
        """
      else
        ""
      end

    """
    # Code Review Request

    ## Repository: #{repo_name}
    #{focus_section}

    ## Codebase Context
    The following code snippets are from the existing codebase and are related to the changes being reviewed:

    #{context}

    ## Changes to Review

    ```diff
    #{diff}
    ```

    Please provide a thorough code review based on the guidelines. Use the codebase context to understand existing patterns and check for consistency.
    """
  end

  @doc """
  System prompt for security-focused review.
  """
  def security_system_prompt do
    """
    You are a security-focused code reviewer specializing in identifying vulnerabilities.

    Focus exclusively on security concerns:
    1. Input validation and sanitization
    2. Authentication and authorization flaws
    3. SQL injection, XSS, CSRF vulnerabilities
    4. Sensitive data exposure
    5. Cryptographic issues
    6. Dependency vulnerabilities
    7. Race conditions and timing attacks

    Format your review with severity ratings:
    - **CRITICAL**: Immediate security risk, must fix before merge
    - **HIGH**: Significant vulnerability, should fix before merge
    - **MEDIUM**: Potential security issue, recommend fixing
    - **LOW**: Minor security improvement suggestion

    ## Security Assessment

    ### Critical Issues
    [List critical vulnerabilities]

    ### High Priority
    [List high priority issues]

    ### Medium Priority
    [List medium priority issues]

    ### Low Priority
    [List low priority suggestions]

    ### Summary
    [Overall security assessment]
    """
  end

  @doc """
  Build security-focused review prompt.
  """
  def security_review_prompt(diff, context, opts \\ []) do
    repo_name = Keyword.get(opts, :repo_name, "repository")

    """
    # Security Review Request

    ## Repository: #{repo_name}

    ## Codebase Context
    #{context}

    ## Changes to Review

    ```diff
    #{diff}
    ```

    Provide a security-focused code review following the security assessment guidelines.
    """
  end

  @doc """
  Get the appropriate prompts for a review type.
  """
  def get_prompts(type, diff, context, opts \\ []) do
    case type do
      :security ->
        {security_system_prompt(), security_review_prompt(diff, context, opts)}

      _ ->
        {system_prompt(), review_prompt(diff, context, opts)}
    end
  end
end
