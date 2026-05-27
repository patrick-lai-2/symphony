defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Thin Jira Cloud REST client used by `SymphonyElixir.Jira.Adapter`.

  Authenticates with HTTP Basic Auth using the configured email + API token.
  Uses the v3 search and issue endpoints.

  Returns issues normalized into `SymphonyElixir.Linear.Issue` structs so the
  orchestrator and downstream consumers don't need to know which tracker
  produced them.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  # Use the modern cursor-paginated search endpoint. The legacy
  # `/rest/api/3/search` was removed (returns 410 Gone).
  @search_path "/rest/api/3/search/jql"
  @issue_path "/rest/api/3/issue"
  @page_size 50
  @max_error_body_log_bytes 1_024

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, tracker} <- configured_tracker() do
      do_search_by_states(tracker.active_states, tracker)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    with {:ok, tracker} <- configured_tracker() do
      do_search_by_states(state_names, tracker)
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    case Enum.uniq(issue_ids) do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, tracker} <- configured_tracker() do
          # Jira's `id` is numeric; identifiers like "JPO-1" are `key`. We accept either.
          clauses =
            ids
            |> Enum.map(&jql_quote/1)
            |> Enum.join(", ")

          jql = "issueKey IN (#{clauses}) OR id IN (#{clauses})"
          do_search(jql, tracker)
        end
    end
  end

  @doc """
  Resolve a status name (e.g. "Done") to its numeric statusId for a given
  issue, scoped to that issue's project + issuetype workflow.
  """
  @spec resolve_status_id(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_status_id(issue_key, status_name) when is_binary(issue_key) and is_binary(status_name) do
    with {:ok, tracker} <- configured_tracker(),
         {:ok, %{status: 200, body: %{"transitions" => transitions}}} <-
           request(:get, "#{@issue_path}/#{issue_key}/transitions", tracker) do
      transitions
      |> Enum.find(fn %{"to" => %{"name" => name}} ->
        String.downcase(name) == String.downcase(status_name)
      end)
      |> case do
        %{"id" => id} -> {:ok, id}
        nil -> {:error, {:transition_not_available, status_name, Enum.map(transitions, &get_in(&1, ["to", "name"]))}}
      end
    else
      {:ok, response} -> {:error, {:jira_api_status, response.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Transition an issue to the given target status by name.
  """
  @spec transition_issue(String.t(), String.t()) :: :ok | {:error, term()}
  def transition_issue(issue_key, status_name)
      when is_binary(issue_key) and is_binary(status_name) do
    with {:ok, tracker} <- configured_tracker(),
         {:ok, transition_id} <- resolve_status_id(issue_key, status_name),
         {:ok, %{status: status}} when status in [200, 204] <-
           request(
             :post,
             "#{@issue_path}/#{issue_key}/transitions",
             tracker,
             %{"transition" => %{"id" => transition_id}}
           ) do
      :ok
    else
      {:ok, %{status: status}} -> {:error, {:jira_api_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec add_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def add_comment(issue_key, body) when is_binary(issue_key) and is_binary(body) do
    payload = %{
      "body" => %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => body}]}
        ]
      }
    }

    with {:ok, tracker} <- configured_tracker() do
      case request(:post, "#{@issue_path}/#{issue_key}/comment", tracker, payload) do
        {:ok, %{status: status}} when status in [200, 201] -> :ok
        {:ok, %{status: status}} -> {:error, {:jira_api_status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Search
  # ---------------------------------------------------------------------------

  defp do_search_by_states([], _tracker), do: {:ok, []}

  defp do_search_by_states(states, tracker) when is_list(states) do
    state_clause =
      states
      |> Enum.map(&jql_quote/1)
      |> Enum.join(", ")

    project_clause =
      case tracker.project_slug do
        slug when is_binary(slug) and slug != "" -> "project = #{jql_quote(slug)} AND "
        _ -> ""
      end

    jql = "#{project_clause}status IN (#{state_clause}) ORDER BY created ASC"

    do_search(jql, tracker)
  end

  defp do_search(jql, tracker), do: do_search_page(jql, tracker, nil, [])

  defp do_search_page(jql, tracker, next_page_token, acc) do
    body = %{
      "jql" => jql,
      "maxResults" => @page_size,
      "fields" => [
        "summary",
        "description",
        "status",
        "priority",
        "labels",
        "assignee",
        "reporter",
        "created",
        "updated",
        "issuetype",
        "parent",
        "issuelinks"
      ]
    }

    body =
      case next_page_token do
        token when is_binary(token) and token != "" -> Map.put(body, "nextPageToken", token)
        _ -> body
      end

    case request(:post, @search_path, tracker, body) do
      {:ok, %{status: 200, body: %{"issues" => issues} = resp}} ->
        normalized = Enum.map(issues, &normalize_issue/1) |> Enum.reject(&is_nil/1)
        new_acc = acc ++ normalized

        case Map.get(resp, "nextPageToken") do
          token when is_binary(token) and token != "" ->
            do_search_page(jql, tracker, token, new_acc)

          _ ->
            {:ok, new_acc}
        end

      {:ok, response} ->
        Logger.error("Jira search failed status=#{response.status} body=#{summarize_body(response.body)}")
        {:error, {:jira_api_status, response.status}}

      {:error, reason} ->
        {:error, {:jira_api_request, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP plumbing
  # ---------------------------------------------------------------------------

  defp configured_tracker do
    tracker = Config.settings!().tracker

    cond do
      blank?(tracker.api_key) ->
        {:error, :missing_jira_api_token}

      blank?(tracker.email) ->
        {:error, :missing_jira_email}

      blank?(tracker.endpoint) ->
        {:error, :missing_jira_endpoint}

      true ->
        {:ok, tracker}
    end
  end

  defp request(method, path, tracker, body \\ nil) do
    url = String.trim_trailing(tracker.endpoint, "/") <> path

    headers = [
      {"Authorization", authorization_header(tracker.email, tracker.api_key)},
      {"Accept", "application/json"},
      {"Content-Type", "application/json"}
    ]

    opts = [headers: headers, connect_options: [timeout: 30_000]]
    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    case method do
      :get -> Req.get(url, opts)
      :post -> Req.post(url, opts)
      :put -> Req.put(url, opts)
    end
  end

  defp authorization_header(email, token) do
    case System.get_env("JIRA_AUTH_SCHEME") do
      scheme when is_binary(scheme) ->
        case String.downcase(String.trim(scheme)) do
          "bearer" -> "Bearer #{token}"
          _ -> basic_auth(email, token)
        end

      _ ->
        basic_auth(email, token)
    end
  end

  defp basic_auth(email, token) do
    "Basic " <> Base.encode64("#{email}:#{token}")
  end

  defp summarize_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp summarize_body(body), do: inspect(body, limit: 20)

  # ---------------------------------------------------------------------------
  # Issue normalization → Linear.Issue (the canonical orchestrator struct)
  # ---------------------------------------------------------------------------

  defp normalize_issue(%{"id" => id, "key" => key, "fields" => fields} = issue)
       when is_binary(id) and is_binary(key) and is_map(fields) do
    %Issue{
      # The orchestrator uses `:id` as a stable opaque handle. Use the key so
      # workspace dirs stay human-readable (e.g. JPO-40635/).
      id: key,
      identifier: key,
      title: Map.get(fields, "summary"),
      description: extract_description(fields),
      priority: parse_priority(Map.get(fields, "priority")),
      state: get_in(fields, ["status", "name"]),
      branch_name: nil,
      url: build_browse_url(issue, key),
      assignee_id: get_in(fields, ["assignee", "accountId"]),
      blocked_by: extract_blockers(Map.get(fields, "issuelinks")),
      labels: extract_labels(fields),
      assigned_to_worker: true,
      created_at: parse_datetime(Map.get(fields, "created")),
      updated_at: parse_datetime(Map.get(fields, "updated"))
    }
  end

  defp normalize_issue(_), do: nil

  defp extract_description(%{"description" => nil}), do: nil

  defp extract_description(%{"description" => %{"content" => content}}) when is_list(content) do
    content
    |> Enum.flat_map(&adf_text/1)
    |> Enum.join("\n")
  end

  defp extract_description(%{"description" => description}) when is_binary(description), do: description

  defp extract_description(_), do: nil

  defp adf_text(%{"type" => "paragraph", "content" => content}) when is_list(content) do
    [content |> Enum.map(&adf_inline_text/1) |> Enum.join("")]
  end

  defp adf_text(%{"type" => "heading", "content" => content}) when is_list(content) do
    [content |> Enum.map(&adf_inline_text/1) |> Enum.join("")]
  end

  defp adf_text(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, &adf_text/1)
  end

  defp adf_text(_), do: []

  defp adf_inline_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp adf_inline_text(%{"type" => "hardBreak"}), do: "\n"
  defp adf_inline_text(_), do: ""

  defp parse_priority(%{"name" => name}) when is_binary(name) do
    case String.downcase(name) do
      "highest" -> 1
      "high" -> 2
      "medium" -> 3
      "low" -> 4
      "lowest" -> 5
      _ -> nil
    end
  end

  defp parse_priority(_), do: nil

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_fields), do: []

  # In Jira, an issue link with type name "Blocks" describes the relationship
  # between two issues. The current issue is "blocked by" the issue referenced
  # via `inwardIssue` (Jira inward direction = "is blocked by"). We extract
  # only those inward "Blocks" links so the orchestrator can defer dispatch
  # until the blocker reaches a terminal state. Outward "Blocks" links (where
  # the current issue blocks another) are intentionally ignored.
  @doc false
  @spec extract_blockers_for_test(term()) :: [map()]
  def extract_blockers_for_test(links), do: extract_blockers(links)

  defp extract_blockers(links) when is_list(links) do
    Enum.flat_map(links, &extract_blocker_from_link/1)
  end

  defp extract_blockers(_), do: []

  defp extract_blocker_from_link(link) when is_map(link) do
    type_name = get_in(link, ["type", "name"])

    cond do
      not is_binary(type_name) ->
        []

      String.downcase(String.trim(type_name)) != "blocks" ->
        []

      is_map(link["inwardIssue"]) ->
        case build_blocker(link["inwardIssue"]) do
          %{identifier: identifier} = blocker when is_binary(identifier) -> [blocker]
          _ -> []
        end

      true ->
        []
    end
  end

  defp extract_blocker_from_link(_), do: []

  defp build_blocker(%{"key" => key} = blocker_issue) when is_binary(key) and key != "" do
    %{
      id: key,
      identifier: key,
      state: get_in(blocker_issue, ["fields", "status", "name"])
    }
  end

  defp build_blocker(_), do: %{id: nil, identifier: nil, state: nil}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  # The Jira `self` URL points at the REST endpoint
  # (e.g. https://example.atlassian.net/rest/api/3/issue/12345); we want the
  # human browse URL https://example.atlassian.net/browse/<KEY>.
  defp build_browse_url(%{"self" => self}, key) when is_binary(self) and is_binary(key) do
    case URI.parse(self) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        port_part = if port in [nil, 80, 443], do: "", else: ":#{port}"
        "#{scheme}://#{host}#{port_part}/browse/#{key}"

      _ ->
        nil
    end
  end

  defp build_browse_url(_issue, _key), do: nil

  defp jql_quote(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
