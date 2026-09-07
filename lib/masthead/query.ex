defmodule Masthead.Query do
  @moduledoc """
  Ordering for the admin list pages.

  `sort/3` applies a clicked column header to a list query. The caller
  names the columns it accepts, so a field arriving from the browser can
  never reach `order_by` unchecked. It replaces the query's own ordering
  rather than adding a second key after it.
  """
  import Ecto.Query

  def sort(query, {field, direction}, allowed) when direction in [:asc, :desc] do
    if field in allowed do
      order_by(exclude(query, :order_by), [q], [{^direction, field(q, ^field)}])
    else
      query
    end
  end

  def sort(query, _sort, _allowed), do: query
end
