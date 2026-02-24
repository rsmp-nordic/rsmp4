defmodule RSMP.Converter do
  @type data :: Map
  @type code :: String
  @type statuses :: Map

  @callback to_rsmp_status(code, data) :: data
  @callback from_rsmp_status(code, data) :: data
  @callback command_default(code, statuses) :: data

  # Returns a zero-value map used as the initial accumulator when aggregating
  # data points into bins. Only needed for numeric-aggregate statuses.
  @callback aggregation_zero() :: map()
  @optional_callbacks aggregation_zero: 0
end
