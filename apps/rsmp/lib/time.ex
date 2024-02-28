defmodule RSMP.Time do
  def now() do
    DateTime.truncate(DateTime.utc_now(), :millisecond)
  end

  def timestamp(time \\ now()) do
    Calendar.strftime(time, "%xT%X.%fZ")
  end
end
