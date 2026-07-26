defmodule Imp.GitIdentityTest do
  use ExUnit.Case, async: true

  alias Imp.GitIdentity

  @sha "59626147df2b0fcd49fdddaf3e7b5980b522a4fb"
  @other "89626147df2b0fcd49fdddaf3e7b5980b522a4fb"

  test "accepts a canonical full SHA without prefix resolution" do
    resolver = fn _prefix -> flunk("full SHAs must not use prefix resolution") end

    assert {:ok, %{canonical: @sha, mode: :full}} =
             GitIdentity.verify(@sha, @sha, resolver)
  end

  test "accepts an approved prefix only when it resolves unambiguously to the full SHA" do
    assert {:ok, %{approved: "5962614", canonical: @sha, mode: :unambiguous_prefix}} =
             GitIdentity.verify("5962614", @sha, fn "5962614" -> {:ok, @sha} end)
  end

  test "rejects ambiguous, mismatched, and underspecified prefixes" do
    assert {:error, {:git_prefix_not_unambiguous, "5962614", :ambiguous}} =
             GitIdentity.verify("5962614", @sha, fn _prefix -> {:error, :ambiguous} end)

    assert {:error, {:git_identity_mismatch, "5962614", @sha}} =
             GitIdentity.verify("5962614", @sha, fn _prefix -> {:ok, @other} end)

    assert {:error, {:invalid_approved_git_identity, "596261"}} =
             GitIdentity.verify("596261", @sha, fn _prefix -> {:ok, @sha} end)
  end

  test "resolves the current repository prefix through git before acceptance" do
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: File.cwd!())
    head = String.trim(head)

    assert {:ok, %{canonical: ^head, mode: :unambiguous_prefix}} =
             GitIdentity.verify_head(File.cwd!(), String.slice(head, 0, 12))
  end
end
