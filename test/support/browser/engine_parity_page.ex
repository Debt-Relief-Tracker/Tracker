defmodule DebtReliefTracker.BrowserCase.EngineParityPage do
  @moduledoc """
  Test-only Hologram page (compiled only in `:test`) that runs the REAL
  `DebtReliefTracker.Engine.Planning`/`Calculations`/`Charts`/`Retirement`
  in the browser on the fixtures in `test/support/fixtures/*_scenarios.json`.

  The server converts the fixtures with `Engine.Convert` (Decimal) and puts
  the plain integer inputs in page state; each button then runs one scenario
  through `EngineDigest` in the client and renders every result as text
  (`<pre data-key=...>`). `EngineParityBrowserTest` compares those texts with
  the same digest computed on the server, exactly.
  """

  use Hologram.Page

  alias DebtReliefTracker.BrowserCase.EngineDigest
  alias DebtReliefTracker.BrowserCase.EngineInputs
  alias DebtReliefTrackerWeb.Holo.QuietJS

  route "/__browser_test/engine"
  layout DebtReliefTrackerWeb.Holo.Layout

  def init(_params, component, _server) do
    inputs = EngineInputs.load()

    component
    |> put_state(:scenarios, inputs.scenarios)
    |> put_state(:jobs, inputs.jobs)
    |> put_state(:results, [])
    |> put_state(:done, 0)
  end

  def template do
    ~HOLO"""
    <div id="engine-page">
      {%for s <- @scenarios}
        <button id="run-scenario-{s.index}" $click={:run_scenario, index: s.index}>{s.index}</button>
      {/for}
      {%for job <- @jobs}
        <button id="run-job-{job.id}" $click={:run_job, id: job.id}>{job.id}</button>
      {/for}
      <p id="done">{@done}</p>
      {%for r <- @results}
        <pre data-key={r.key}>{r.text}</pre>
      {/for}
    </div>
    """
  end

  def action(:run_scenario, %{index: index}, component) do
    QuietJS.quiet()
    scenario = Enum.find(component.state.scenarios, &(&1.index == index))
    finish(component, "sc#{index}", EngineDigest.scenario(scenario))
  end

  # One profile set's baseline, or one of its debt cases (each its own job so
  # a single click stays short).
  def action(:run_job, %{id: id}, component) do
    QuietJS.quiet()
    job = Enum.find(component.state.jobs, &(&1.id == id))

    digest =
      case job.case do
        nil -> EngineDigest.retirement_base(job.profiles)
        case_ -> EngineDigest.retirement_case(job.profiles, case_)
      end

    finish(component, "set#{job.set}", digest)
  end

  defp finish(component, prefix, digest) do
    rows = Enum.map(digest, fn {key, text} -> %{key: "#{prefix}/#{key}", text: text} end)

    component
    |> put_state(:results, component.state.results ++ rows)
    |> put_state(:done, component.state.done + 1)
  end
end
