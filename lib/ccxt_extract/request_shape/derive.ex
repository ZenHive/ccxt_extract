defmodule CcxtExtract.RequestShape.Derive do
  @moduledoc """
  Orchestrator for `structure.request_shape` derivation. Mirrors the
  layout of `CcxtExtract.SignRecipe.Derive` — one entry point that
  scans the inputs once, then delegates per-field work to
  `VerbPath` (Task 70) and `BodyEncoding` (Task 71).

  # Patch count: 0/3. First patch migrates to priv/overrides/.
  # See ROADMAP.md § Phase 11 "Three-Strikes Rule".

  ## Inputs

    * `sign_method` — MethodAST map for `sign()`, or `nil`. The
      body-encoding pass walks `sign_method["body"]["body"]`. When
      absent we tag every section's record with
      `unresolved_reason: "no_sign_method"`.

    * `auth_sections` — sorted list of section names from
      `CcxtExtract.AuthenticatedSections.derive/2`, or `nil`/`[]`.
      Empty inputs return `%{}` (no auth → no recipe → no shape).

    * `describe_api` — full `runtime.describe.api` map, or `nil`.
      The verb/path pass walks the section subtree to enumerate
      endpoints. When the map is absent or the section can't be
      resolved we tag the record with `"no_describe_api"` /
      `"section_not_in_api"`.

  ## Output

  Returns a `section_name => record` map matching the shape of
  `CcxtExtract.RequestShape.null_record/0`. Every authenticated
  section gets one record. Records carry a populated set of
  derivation fields when both axes succeed; otherwise the
  `unresolved_reason` slot tracks why.

  ## Biconditional

  When every derivation field is populated (per
  `RequestShape.all_derivation_fields_populated?/1`) AND the
  intermediate `unresolved_reason` is the scaffold `"not_yet_derived"`,
  the orchestrator flips `unresolved_reason` to `nil`. Terminal
  reasons (`"no_sign_method"`, `"no_describe_api"`,
  `"section_not_in_api"`, `"ambiguous_body"`) pass through unchanged
  — by construction those records have at least one null derivation
  field, so the biconditional holds trivially.
  """

  alias CcxtExtract.RequestShape
  alias CcxtExtract.RequestShape.BodyEncoding
  alias CcxtExtract.RequestShape.VerbPath

  @terminal_reasons RequestShape.terminal_reasons()

  @doc """
  Build the `section_name => record` map.
  """
  @spec derive(map() | nil, [String.t()] | nil, map() | nil) ::
          RequestShape.record_map()
  def derive(_sign_method, nil, _describe_api), do: %{}
  def derive(_sign_method, [], _describe_api), do: %{}

  def derive(sign_method, auth_sections, describe_api) when is_list(auth_sections) do
    body_stmts = sign_body_stmts(sign_method)
    body_result = BodyEncoding.derive(body_stmts)

    Map.new(auth_sections, fn section ->
      {section, derive_section(section, body_result, describe_api)}
    end)
  end

  def derive(_sign_method, _auth_sections, _describe_api), do: %{}

  # --- Per-section assembly ---

  defp derive_section(section, body_result, describe_api) do
    {endpoints, endpoints_reason} = derive_endpoints(describe_api, section)

    # Section-level reason precedence: terminal endpoints reasons
    # (`"no_describe_api"`, `"section_not_in_api"`) and
    # `"no_sign_method"` short-circuit the whole record. A non-
    # terminal `"ambiguous_body"` only nulls the body fields and
    # surfaces on the parent record; endpoints stay populated.
    section_reason = pick_section_reason(endpoints_reason, body_result.reason)

    {endpoints_value, body_value, content_value} =
      pick_field_values(section_reason, endpoints, body_result)

    record =
      RequestShape.null_record()
      |> Map.put("endpoints", endpoints_value)
      |> Map.put("body_encoding", body_value)
      |> Map.put("content_type", content_value)
      |> Map.put("unresolved_reason", initial_reason(section_reason))

    resolve_unresolved_reason(record)
  end

  # Convert the VerbPath result tuple into `{endpoints_or_nil, reason_or_nil}`.
  defp derive_endpoints(describe_api, section) do
    case VerbPath.derive(describe_api, section) do
      {:ok, endpoints} -> {endpoints, nil}
      {:error, reason} -> {nil, reason}
    end
  end

  # Reason precedence — endpoints terminal reasons win because
  # without endpoints there's no actionable shape; otherwise the body
  # reason surfaces (terminal `"no_sign_method"` or non-terminal
  # `"ambiguous_body"`).
  defp pick_section_reason(endpoints_reason, _body_reason) when is_binary(endpoints_reason), do: endpoints_reason

  defp pick_section_reason(_endpoints_reason, body_reason), do: body_reason

  # Decide which derivation fields populate vs null based on which
  # terminal reason (if any) applies.
  defp pick_field_values(reason, endpoints, _body_result) when reason in @terminal_reasons do
    case reason do
      "no_sign_method" ->
        # sign() AST absent — body fields can't be derived, but
        # endpoints from describe.api still resolve. Honesty-Rule:
        # null both body fields, keep endpoints.
        {endpoints, nil, nil}

      _ ->
        # Endpoints terminal reasons (`"no_describe_api"`,
        # `"section_not_in_api"`) null the entire record's
        # derivation triple — without describe.api we can't honestly
        # claim any structured shape.
        {nil, nil, nil}
    end
  end

  # Non-terminal reason (`"ambiguous_body"`) — null body fields, keep
  # endpoints. Or no reason at all — every field passes through.
  defp pick_field_values("ambiguous_body", endpoints, _body_result) do
    {endpoints, nil, nil}
  end

  defp pick_field_values(_reason, endpoints, body_result) do
    {endpoints, body_result.body_encoding, body_result.content_type}
  end

  defp initial_reason(nil), do: "not_yet_derived"
  defp initial_reason(reason) when is_binary(reason), do: reason

  # Write-side biconditional: scaffold `"not_yet_derived"` flips to
  # nil exactly when every derivation field populates per
  # `RequestShape.all_derivation_fields_populated?/1`. Read-side
  # invariant `request_shape_honesty_valid` enforces the other
  # direction.
  defp resolve_unresolved_reason(%{"unresolved_reason" => "not_yet_derived"} = record) do
    if RequestShape.all_derivation_fields_populated?(record) do
      Map.put(record, "unresolved_reason", nil)
    else
      record
    end
  end

  defp resolve_unresolved_reason(record), do: record

  defp sign_body_stmts(%{"body" => %{"body" => body_stmts}}) when is_list(body_stmts), do: body_stmts
  defp sign_body_stmts(_), do: nil
end
