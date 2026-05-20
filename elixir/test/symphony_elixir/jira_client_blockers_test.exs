defmodule SymphonyElixir.JiraClientBlockersTest do
  @moduledoc """
  Unit tests for `SymphonyElixir.Jira.Client.extract_blockers/1`.

  The fixtures here are minimised snapshots of real Jira Cloud REST v3
  `issuelinks` payloads captured from the `plai2.atlassian.net` site (PD
  project, e.g. PD-86 — see session log). They cover the shape produced by
  Jira for the built-in "Blocks" link type plus several defensive edge cases.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Jira.Client

  # Helper to build a realistic Jira "Blocks" issue link payload.
  defp blocks_link(opts) do
    direction = Keyword.fetch!(opts, :direction)
    key = Keyword.fetch!(opts, :key)
    id = Keyword.get(opts, :id, "10000")
    status_name = Keyword.get(opts, :status_name, "To Do")
    status_category = Keyword.get(opts, :status_category, "new")
    type_name = Keyword.get(opts, :type_name, "Blocks")

    issue_payload = %{
      "id" => id,
      "key" => key,
      "self" => "https://api.atlassian.com/ex/jira/abc/rest/api/3/issue/#{id}",
      "fields" => %{
        "summary" => "Blocker #{key}",
        "status" => %{
          "name" => status_name,
          "id" => "10043",
          "statusCategory" => %{
            "key" => status_category,
            "name" => String.capitalize(status_category)
          }
        }
      }
    }

    base = %{
      "id" => "link-#{id}",
      "type" => %{
        "id" => "10000",
        "name" => type_name,
        "inward" => "is blocked by",
        "outward" => "blocks"
      }
    }

    case direction do
      :inward -> Map.put(base, "inwardIssue", issue_payload)
      :outward -> Map.put(base, "outwardIssue", issue_payload)
    end
  end

  describe "extract_blockers/1 with real-shaped Jira payloads" do
    test "extracts inward Blocks links into id/identifier/state triples" do
      links = [
        blocks_link(direction: :inward, key: "PD-82", id: "10262", status_name: "To Do"),
        blocks_link(direction: :inward, key: "PD-85", id: "10268", status_name: "In Progress"),
        blocks_link(direction: :inward, key: "PD-83", id: "10264", status_name: "Done")
      ]

      assert Client.extract_blockers_for_test(links) == [
               %{id: "PD-82", identifier: "PD-82", state: "To Do"},
               %{id: "PD-85", identifier: "PD-85", state: "In Progress"},
               %{id: "PD-83", identifier: "PD-83", state: "Done"}
             ]
    end

    test "ignores outward Blocks links (issues this one blocks, not is blocked by)" do
      links = [
        blocks_link(direction: :outward, key: "PD-86", id: "10270", status_name: "To Do"),
        blocks_link(direction: :inward, key: "PD-81", id: "10260", status_name: "Done")
      ]

      assert Client.extract_blockers_for_test(links) == [
               %{id: "PD-81", identifier: "PD-81", state: "Done"}
             ]
    end

    test "ignores non-Blocks link types (e.g. Relates, Clones, Duplicates)" do
      links = [
        Map.put(blocks_link(direction: :inward, key: "PD-50"), "type", %{
          "name" => "Relates",
          "inward" => "relates to",
          "outward" => "relates to"
        }),
        Map.put(blocks_link(direction: :inward, key: "PD-51"), "type", %{
          "name" => "Cloners",
          "inward" => "is cloned by",
          "outward" => "clones"
        }),
        blocks_link(direction: :inward, key: "PD-52", status_name: "Done")
      ]

      assert Client.extract_blockers_for_test(links) == [
               %{id: "PD-52", identifier: "PD-52", state: "Done"}
             ]
    end

    test "matches the Blocks type name case- and whitespace-insensitively" do
      links = [
        Map.put(blocks_link(direction: :inward, key: "PD-1"), "type", %{
          "name" => "  blocks  "
        }),
        Map.put(blocks_link(direction: :inward, key: "PD-2"), "type", %{"name" => "BLOCKS"}),
        Map.put(blocks_link(direction: :inward, key: "PD-3"), "type", %{"name" => "BlOcKs"})
      ]

      assert [
               %{identifier: "PD-1"},
               %{identifier: "PD-2"},
               %{identifier: "PD-3"}
             ] = Client.extract_blockers_for_test(links)
    end

    test "preserves order of inward Blocks links as returned by Jira" do
      links =
        for key <- ["PD-90", "PD-80", "PD-70", "PD-60"] do
          blocks_link(direction: :inward, key: key, status_name: "To Do")
        end

      assert Enum.map(Client.extract_blockers_for_test(links), & &1.identifier) ==
               ["PD-90", "PD-80", "PD-70", "PD-60"]
    end

    test "captures status name as state, even for non-terminal statuses" do
      links = [
        blocks_link(direction: :inward, key: "PD-10", status_name: "Selected for Development"),
        blocks_link(direction: :inward, key: "PD-11", status_name: "In Review"),
        blocks_link(direction: :inward, key: "PD-12", status_name: "Done")
      ]

      assert Enum.map(Client.extract_blockers_for_test(links), & &1.state) ==
               ["Selected for Development", "In Review", "Done"]
    end

    test "returns nil state when the inward issue is missing fields.status.name" do
      link =
        blocks_link(direction: :inward, key: "PD-200")
        |> put_in(["inwardIssue", "fields"], %{})

      assert Client.extract_blockers_for_test([link]) == [
               %{id: "PD-200", identifier: "PD-200", state: nil}
             ]
    end
  end

  describe "extract_blockers/1 defensive handling" do
    test "returns [] for non-list input" do
      assert Client.extract_blockers_for_test(nil) == []
      assert Client.extract_blockers_for_test(%{}) == []
      assert Client.extract_blockers_for_test("not a list") == []
    end

    test "returns [] for an empty list" do
      assert Client.extract_blockers_for_test([]) == []
    end

    test "skips link entries that are not maps without crashing" do
      links = [
        nil,
        "garbage",
        42,
        blocks_link(direction: :inward, key: "PD-300", status_name: "Done")
      ]

      assert Client.extract_blockers_for_test(links) == [
               %{id: "PD-300", identifier: "PD-300", state: "Done"}
             ]
    end

    test "drops links that have a Blocks type but no inwardIssue or outwardIssue" do
      links = [
        %{
          "id" => "broken-1",
          "type" => %{"name" => "Blocks", "inward" => "is blocked by", "outward" => "blocks"}
        },
        blocks_link(direction: :inward, key: "PD-301", status_name: "Done")
      ]

      assert Client.extract_blockers_for_test(links) == [
               %{id: "PD-301", identifier: "PD-301", state: "Done"}
             ]
    end

    test "drops links where the inwardIssue is malformed (missing key)" do
      malformed = %{
        "id" => "bad-link",
        "type" => %{"name" => "Blocks"},
        "inwardIssue" => %{"id" => "10999", "fields" => %{"status" => %{"name" => "To Do"}}}
      }

      good = blocks_link(direction: :inward, key: "PD-302", status_name: "Done")

      assert Client.extract_blockers_for_test([malformed, good]) == [
               %{id: "PD-302", identifier: "PD-302", state: "Done"}
             ]
    end

    test "drops links whose type has no name" do
      links = [
        %{"id" => "x", "type" => %{"id" => "10000"}, "inwardIssue" => %{"key" => "PD-400"}},
        %{"id" => "y", "inwardIssue" => %{"key" => "PD-401"}},
        blocks_link(direction: :inward, key: "PD-402", status_name: "Done")
      ]

      assert Client.extract_blockers_for_test(links) == [
               %{id: "PD-402", identifier: "PD-402", state: "Done"}
             ]
    end
  end
end
