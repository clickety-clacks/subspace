defmodule Subspace.RateLimit.TokenBucket do
  @moduledoc """
  Pure token bucket logic for rate limiting.
  No side effects - all state passed in and out.
  """

  @type bucket :: %{
          tokens: float(),
          last_refill_mono: integer(),
          capacity: integer(),
          refill_per_sec: float(),
          updated_at_mono: integer()
        }

  @doc """
  Creates a new bucket with full capacity.
  """
  def new(capacity, refill_per_sec) when capacity > 0 and refill_per_sec > 0 do
    now_mono = :erlang.monotonic_time(:millisecond)

    %{
      tokens: capacity * 1.0,
      last_refill_mono: now_mono,
      capacity: capacity,
      refill_per_sec: refill_per_sec,
      updated_at_mono: now_mono
    }
  end

  @doc """
  Attempts to consume 1 token from the bucket.
  Returns {:ok, updated_bucket} on success.
  Returns {:error, retry_after_secs, updated_bucket} when rate limited.
  """
  def consume(bucket, now_mono \\ nil) do
    now_mono = now_mono || :erlang.monotonic_time(:millisecond)
    bucket = refill(bucket, now_mono)

    if bucket.tokens >= 1.0 do
      updated = %{bucket | tokens: bucket.tokens - 1.0, updated_at_mono: now_mono}
      {:ok, updated}
    else
      retry_after = calculate_retry_after(bucket)
      updated = %{bucket | updated_at_mono: now_mono}
      {:error, retry_after, updated}
    end
  end

  @doc """
  Refills the bucket based on elapsed time.
  """
  def refill(bucket, now_mono \\ nil) do
    now_mono = now_mono || :erlang.monotonic_time(:millisecond)
    elapsed_ms = max(0, now_mono - bucket.last_refill_mono)
    elapsed_sec = elapsed_ms / 1000.0
    tokens_to_add = elapsed_sec * bucket.refill_per_sec
    new_tokens = min(bucket.capacity * 1.0, bucket.tokens + tokens_to_add)

    %{bucket | tokens: new_tokens, last_refill_mono: now_mono}
  end

  @doc """
  Calculates seconds until a token is available.
  """
  def calculate_retry_after(bucket) do
    if bucket.tokens >= 1.0 do
      0
    else
      tokens_needed = 1.0 - bucket.tokens
      seconds = tokens_needed / bucket.refill_per_sec
      max(1, ceil(seconds))
    end
  end

  @doc """
  Returns true if bucket has been idle for longer than the given milliseconds.
  """
  def idle_for?(bucket, idle_ms, now_mono \\ nil) do
    now_mono = now_mono || :erlang.monotonic_time(:millisecond)
    now_mono - bucket.updated_at_mono > idle_ms
  end
end
