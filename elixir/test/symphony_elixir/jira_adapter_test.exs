defmodule SymphonyElixir.JiraAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Jira.Adapter

  defmodule FakeJiraClient do
    @moduledoc false

    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(ids) do
      send(self(), {:fetch_issue_states_by_ids_called, ids})
      {:ok, ids}
    end

    def add_comment(issue_key, body) do
      send(self(), {:add_comment_called, issue_key, body})
      Process.get({__MODULE__, :add_comment_result}, :ok)
    end

    def transition_issue(issue_key, status_name) do
      send(self(), {:transition_issue_called, issue_key, status_name})
      Process.get({__MODULE__, :transition_issue_result}, :ok)
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :jira_client_module)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :jira_client_module)
      else
        Application.put_env(:symphony_elixir, :jira_client_module, previous)
      end
    end)

    Application.put_env(:symphony_elixir, :jira_client_module, FakeJiraClient)
    :ok
  end

  test "tracker dispatches to the Jira adapter when kind is jira" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_endpoint: "https://example.atlassian.net",
      tracker_api_token: "token",
      tracker_project_slug: "EX",
      tracker_email: "agent@example.com"
    )

    assert Config.settings!().tracker.kind == "jira"
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "adapter delegates reads to the configured Jira client" do
    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["EX-1"]} = Adapter.fetch_issue_states_by_ids(["EX-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["EX-1"]}
  end

  test "adapter delegates writes to the configured Jira client" do
    assert :ok = Adapter.create_comment("EX-1", "hello")
    assert_receive {:add_comment_called, "EX-1", "hello"}

    assert :ok = Adapter.update_issue_state("EX-1", "Done")
    assert_receive {:transition_issue_called, "EX-1", "Done"}
  end

  test "adapter propagates client error tuples" do
    Process.put({FakeJiraClient, :add_comment_result}, {:error, :boom})
    assert {:error, :boom} = Adapter.create_comment("EX-1", "broken")

    Process.put({FakeJiraClient, :transition_issue_result}, {:error, :no_transition})
    assert {:error, :no_transition} = Adapter.update_issue_state("EX-1", "Nope")
  end

  test "an explicit tracker_module override takes precedence over the configured kind" do
    defmodule OverrideAdapter do
      def fetch_candidate_issues, do: {:ok, [:override]}
      def fetch_issues_by_states(_), do: {:ok, []}
      def fetch_issue_states_by_ids(_), do: {:ok, []}
      def create_comment(_, _), do: :ok
      def update_issue_state(_, _), do: :ok
    end

    previous = Application.get_env(:symphony_elixir, :tracker_module)
    Application.put_env(:symphony_elixir, :tracker_module, OverrideAdapter)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_endpoint: "https://example.atlassian.net",
      tracker_api_token: "token",
      tracker_project_slug: "EX",
      tracker_email: "agent@example.com"
    )

    assert SymphonyElixir.Tracker.adapter() == OverrideAdapter
    assert {:ok, [:override]} = SymphonyElixir.Tracker.fetch_candidate_issues()
  end

  test "config validation surfaces missing Jira fields" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_endpoint: "https://example.atlassian.net",
      tracker_api_token: nil,
      tracker_email: "agent@example.com",
      tracker_project_slug: "EX"
    )

    assert {:error, :missing_jira_api_token} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_endpoint: "https://example.atlassian.net",
      tracker_api_token: "token",
      tracker_email: nil,
      tracker_project_slug: "EX"
    )

    # Jira email may be set via the JIRA_EMAIL env fallback; clear it so the
    # validation actually fires.
    previous_email = System.get_env("JIRA_EMAIL")
    previous_atlassian_email = System.get_env("ATLASSIAN_EMAIL")
    System.delete_env("JIRA_EMAIL")
    System.delete_env("ATLASSIAN_EMAIL")

    on_exit(fn ->
      restore_env("JIRA_EMAIL", previous_email)
      restore_env("ATLASSIAN_EMAIL", previous_atlassian_email)
    end)

    assert {:error, :missing_jira_email} = Config.validate!()

    previous_endpoint = System.get_env("JIRA_ENDPOINT")
    System.delete_env("JIRA_ENDPOINT")

    on_exit(fn ->
      restore_env("JIRA_ENDPOINT", previous_endpoint)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_endpoint: nil,
      tracker_api_token: "token",
      tracker_email: "agent@example.com",
      tracker_project_slug: "EX"
    )

    assert {:error, :missing_jira_endpoint} = Config.validate!()
  end
end
