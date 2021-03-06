defmodule ExopPlug do
  @moduledoc """
  Offers a simple DSL to define a plug with number of actions and parameters with validation checks.
  Then you use this plug in corresponding controller and that's it: once HTTP request comes,
  your controller's plug takes an action: it figures out whether this particular HTTP request's
  parameters should be validated or not, and if yes - validates them.

  If parameters pass the validation ExopPlug returns `Plug.Conn` (as usual plug does),
  if not - it returns an error-tuple as described [here](https://github.com/madeinussr/exop#operation-results).

  ExopPlug doesn't transform your HTTP request nor `Plug.Conn.t()` structure.
  So, if you define `get '/user/:user_id'` in your router you receive `%{"user_id" => "1"}` for
  the request `http://localhost:4000/user/1`. There is no any coercion or type inference done
  under the scenes.

  ## Example

      # your plug
      defmodule MyAppWeb.UserControllerPlug do
        use ExopPlug

        action(:show, params: %{"id" => [type: :string, length: %{min: 5}]})
      end

      # in your controller
      defmodule MyAppWeb.UserController do
        use MyAppWeb, :controller

        plug MyAppWeb.UserControllerPlug

        # ...

        def show(conn, params) do
          json(conn, params)
        end

        # ...
      end

  ## action options

  Apart from mandatory `:params` option with which you define an action parameters checks,
  you are able to use other additional options:

  - `:on_fail` - with this option you specify a callback function which is invoked if a parameter
  fails your validation

  Example:

      defmodule MyAppWeb.UserControllerPlug do
        use ExopPlug

        action(:show, params: %{"id" => [type: :string]}, on_fail: &__MODULE__.on_fail/3)

        def on_fail(conn, action_name, errors_map) do
          Plug.Conn.assign(conn, :errors, errors_map)
        end
      end

  ## Exop parameter options

  When you're defining your action's checks you already have a number of useful checks and options
  which come with Exop, for example, `:coerce_with` may be very useful. Check Exop [docs](https://github.com/madeinussr/exop)
  to find out more available options.
  """

  defmacro __using__(_opts) do
    quote do
      import unquote(__MODULE__)

      Module.register_attribute(__MODULE__, :contract, accumulate: true)

      @module_name __MODULE__

      @before_compile unquote(__MODULE__)
    end
  end

  defmacro __before_compile__(_env) do
    quote generated: true, location: :keep do
      if is_nil(@contract) || Enum.count(@contract) == 0 do
        file = String.to_charlist(__ENV__.file())
        line = __ENV__.line()
        stacktrace = [{__MODULE__, :init, 1, [file: file, line: line]}]
        msg = "A plug without an action definition"

        IO.warn(msg, stacktrace)
      else
        Enum.each(@contract, fn %{action_name: action_name, opts: %{params: params}} ->
          params = Macro.escape(params)

          operation_body =
            quote generated: true, location: :keep do
              use Exop.Operation

              @contract Enum.reduce(unquote(params), %{}, fn {param_name, param_opts}, acc ->
                          Map.merge(acc, %{name: param_name, opts: param_opts})
                        end)

              parameter(:conn, struct: Plug.Conn)

              def process(%{conn: conn}), do: conn
            end

          Module.create(
            :"#{__MODULE__}.#{String.capitalize(Atom.to_string(action_name))}",
            operation_body,
            Macro.Env.location(__ENV__)
          )
        end)
      end

      @spec contract :: list(map())
      def contract, do: @contract

      @spec init(Plug.opts()) :: Plug.opts()
      def init(opts), do: opts

      @spec call(Plug.Conn.t(), Plug.opts()) :: Plug.Conn.t() | map() | any()
      def call(
            %Plug.Conn{private: %{phoenix_action: phoenix_action}, params: conn_params} = conn,
            opts \\ []
          ) do
        action_contract =
          Enum.find(@contract, fn
            %{action_name: ^phoenix_action} -> true
            _ -> false
          end)

        {params_specs, on_fail} =
          case action_contract do
            %{opts: %{params: %{} = params_specs, on_fail: on_fail}} -> {params_specs, on_fail}
            _ -> {[], nil}
          end

        if Enum.empty?(params_specs) do
          conn
        else
          operation_module = :"#{__MODULE__}.#{String.capitalize(Atom.to_string(phoenix_action))}"
          operation_params = Map.put(conn_params, :conn, conn)
          operation_result = Kernel.apply(operation_module, :run, [operation_params])

          case operation_result do
            {:ok, %Plug.Conn{} = conn} ->
              conn

            {:error, {:validation, errors_map}} = error ->
              if is_function(on_fail) do
                on_fail.(conn, phoenix_action, errors_map)
              else
                %{phoenix_action => error}
              end
          end
        end
      end
    end
  end

  @doc "Defines incoming parameters validation for your Phoenix controller's action."
  @spec action(atom() | binary(), keyword()) :: any()
  defmacro action(action_name, opts \\ [])
           when (is_atom(action_name) or is_binary(action_name)) and is_list(opts) do
    quote generated: true, bind_quoted: [action_name: action_name, opts: opts] do
      file = String.to_charlist(__ENV__.file())
      line = __ENV__.line()
      stacktrace = [{__MODULE__, :action, 2, [file: file, line: line]}]

      already_has_action? =
        Enum.any?(@contract, fn
          %{action_name: ^action_name} -> true
          _ -> false
        end)

      if already_has_action? do
        raise(CompileError,
          file: file,
          line: line,
          description: "`#{action_name}` action is duplicated"
        )
      else
        opts = Enum.into(opts, %{})

        params = Map.get(opts, :params, :nothing)

        params =
          cond do
            is_list(params) and Enum.empty?(params) -> :nothing
            is_list(params) -> Enum.into(params, %{})
            is_map(params) and Enum.empty?(params) -> :nothing
            is_map(params) -> params
            true -> :nothing
          end

        opts =
          if params == :nothing do
            IO.warn(
              "`#{action_name}` action has been defined without params specification and will be omited during the validation",
              stacktrace
            )

            Map.put(opts, :params, %{})
          else
            opts
          end

        on_fail = Map.get(opts, :on_fail, :nothing)

        opts =
          cond do
            on_fail == :nothing ->
              Map.put(opts, :on_fail, nil)

            is_function(on_fail) && on_fail |> Function.info() |> Keyword.get(:arity, 0) == 3 ->
              opts

            is_function(on_fail) ->
              raise(CompileError,
                file: file,
                line: line,
                description: "`#{action_name}` action's `on_fail` callback should have arity = 3"
              )

            true ->
              raise(CompileError,
                file: file,
                line: line,
                description: "`#{action_name}` action's `on_fail` callback is not a function"
              )
          end

        @contract %{action_name: action_name, opts: opts}
      end
    end
  end
end
