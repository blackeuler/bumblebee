defmodule Bumblebee.Vision.Vit do
  alias Bumblebee.Shared

  options =
    [
      image_size: [
        default: 224,
        doc: "the size of the input spatial dimensions"
      ],
      num_channels: [
        default: 3,
        doc: "the number of channels in the input"
      ],
      patch_size: [
        default: 16,
        doc: "the size of the patch spatial dimensions"
      ],
      hidden_size: [
        default: 768,
        doc: "the dimensionality of hidden layers"
      ],
      num_blocks: [
        default: 12,
        doc: "the number of Transformer blocks in the encoder"
      ],
      num_attention_heads: [
        default: 12,
        doc: "the number of attention heads for each attention layer in the encoder"
      ],
      intermediate_size: [
        default: 3072,
        docs:
          "the dimensionality of the intermediate (often named feed-forward) layer in the encoder"
      ],
      use_qkv_bias: [
        default: true,
        doc: "whether to use bias in query, key, and value projections"
      ],
      activation: [
        default: :gelu,
        doc: "the activation function"
      ],
      dropout_rate: [
        default: 0.0,
        doc: "the dropout rate for encoder and decoder"
      ],
      attention_dropout_rate: [
        default: 0.0,
        doc: "the dropout rate for attention weights"
      ],
      layer_norm_epsilon: [
        default: 1.0e-12,
        doc: "the epsilon used by the layer normalization layers"
      ],
      initializer_scale: [
        default: 0.02,
        doc:
          "the standard deviation of the normal initializer used for initializing kernel parameters"
      ]
    ] ++
      Shared.common_options([
        :output_hidden_states,
        :output_attentions,
        :num_labels,
        :id_to_label
      ])

  @moduledoc """
  Models based on the ViT architecture.

  ## Architectures

    * `:base` - plain ViT without any head on top

    * `:for_image_classification` - ViT with a classification head.
      The head consists of a single dense layer on top of the pooled
      features

    * `:for_masked_image_modeling` - ViT with a language modeling
      head on top for predicting visual tokens

  ## Inputs

    * `"pixel_values"` - `{batch_size, num_channels, image_size, image_size}`

      Featurized image pixel values.

    * `"patch_mask"` - `{batch_size, num_patches}`

      Mask to nullify selected embedded patches.

  ## Configuration

  #{Shared.options_doc(options)}

  ## References

    * [An Image is Worth 16x16 Words: Transformers for Image Recognition at Scale](https://arxiv.org/abs/2010.11929)
  """

  import Bumblebee.Utils.Model, only: [join: 2]

  alias Bumblebee.Layers

  defstruct [architecture: :base] ++ Shared.option_defaults(options)

  @behaviour Bumblebee.ModelSpec
  @behaviour Bumblebee.Configurable

  @impl true
  def architectures(), do: [:base, :for_image_classification, :for_masked_image_modeling]

  @impl true
  def base_model_prefix(), do: "vit"

  @impl true
  def config(config, opts \\ []) do
    config
    |> Shared.put_config_attrs(opts)
    |> Shared.validate_label_options()
  end

  @impl true
  def input_template(config) do
    %{
      "pixel_values" =>
        Nx.template({1, config.num_channels, config.image_size, config.image_size}, :f32)
    }
  end

  @impl true
  def model(%__MODULE__{architecture: :for_image_classification} = config) do
    outputs =
      config
      |> inputs()
      |> vit(config, name: "vit")

    logits =
      outputs.last_hidden_state
      |> Layers.take_token(index: 0, axis: 1, name: join("vit", "head"))
      |> Axon.dense(config.num_labels,
        kernel_initializer: kernel_initializer(config),
        name: "classifier"
      )

    Layers.output(%{
      logits: logits,
      hidden_states: outputs.hidden_states,
      attentions: outputs.attentions
    })
  end

  def model(%__MODULE__{architecture: :for_masked_image_modeling} = config) do
    outputs =
      config
      |> inputs()
      |> vit(config, name: "vit")

    logits =
      outputs.last_hidden_state
      |> Axon.nx(fn x ->
        x = x[[0..-1//1, 1..-1//1]]

        {batch_size, seq_length, channels} = Nx.shape(x)
        height = width = seq_length |> :math.sqrt() |> floor()

        x
        |> Nx.transpose(axes: [0, 2, 1])
        |> Nx.reshape({batch_size, channels, height, width})
      end)
      # Upsample to the original spatial resolution
      |> Axon.conv(config.patch_size ** 2 * 3,
        kernel_size: 1,
        kernel_initializer: kernel_initializer(config),
        name: join("decoder", 0)
      )
      |> Layers.pixel_shuffle(config.patch_size, name: join("decoder", 1))

    Layers.output(%{
      logits: logits,
      hidden_states: outputs.hidden_states,
      attentions: outputs.attentions
    })
  end

  def model(%__MODULE__{architecture: :base} = config) do
    config
    |> inputs()
    |> vit(config)
    |> Layers.output()
  end

  defp inputs(config) do
    shape = {nil, config.num_channels, config.image_size, config.image_size}

    Bumblebee.Utils.Model.inputs_to_map([
      Axon.input("pixel_values", shape: shape),
      Axon.input("patch_mask", shape: {nil, nil}, optional: true)
    ])
  end

  defp vit(inputs, config, opts \\ []) do
    name = opts[:name]

    hidden_state = embeddings(inputs, config, name: join(name, "embeddings"))

    {hidden_state, hidden_states, attentions} =
      encoder(hidden_state, config, name: join(name, "encoder"))

    last_hidden_state =
      hidden_state
      |> Axon.layer_norm(
        channel_index: 2,
        epsilon: config.layer_norm_epsilon,
        name: join(name, "layernorm")
      )

    pooled = pooler(last_hidden_state, config, name: join(name, "pooler"))

    %{
      last_hidden_state: last_hidden_state,
      pooler_output: pooled,
      hidden_states: hidden_states,
      attentions: attentions
    }
  end

  defp embeddings(inputs, config, opts) do
    name = opts[:name]

    inputs["pixel_values"]
    |> patch_embeddings(config, name: join(name, "patch_embeddings"))
    |> Layers.apply_vision_patch_mask(inputs["patch_mask"], name: join(name, "mask_tokens"))
    |> position_embeddings(config, name: name)
    |> Axon.dropout(rate: config.dropout_rate, name: join(name, "dropout"))
  end

  defp patch_embeddings(pixel_values, config, opts) do
    name = opts[:name]

    pixel_values
    |> Axon.conv(config.hidden_size,
      kernel_size: config.patch_size,
      strides: config.patch_size,
      padding: :valid,
      kernel_initializer: kernel_initializer(config),
      name: join(name, "projection")
    )
    |> Axon.nx(&Nx.transpose(&1, axes: [0, 2, 3, 1]))
    |> Axon.reshape({:batch, :auto, config.hidden_size}, name: join(name, "reshape"))
  end

  defp position_embeddings(embeddings, config, opts) do
    name = opts[:name]

    num_patches =
      div(config.image_size, config.patch_size) * div(config.image_size, config.patch_size)

    cls_token =
      Axon.param("cls_token", fn _ -> {1, 1, config.hidden_size} end, initializer: :zeros)

    position_embeddings =
      Axon.param("position_embeddings", fn _ -> {1, num_patches + 1, config.hidden_size} end,
        initializer: :zeros
      )

    Axon.layer(
      fn embeddings, cls_token, position_embeddings, _opts ->
        batch_size = Nx.axis_size(embeddings, 0)
        cls_token = Nx.broadcast(cls_token, {batch_size, 1, config.hidden_size})

        Nx.concatenate([cls_token, embeddings], axis: 1)
        |> Nx.add(position_embeddings)
      end,
      [embeddings, cls_token, position_embeddings],
      name: name
    )
  end

  defp encoder(hidden_state, config, opts) do
    name = opts[:name]

    encoder_blocks(hidden_state, config, name: join(name, "layer"))
  end

  defp encoder_blocks(hidden_state, config, opts) do
    name = opts[:name]

    hidden_states = Layers.maybe_container({hidden_state}, config.output_hidden_states)
    attentions = Layers.maybe_container({}, config.output_attentions)

    for idx <- 0..(config.num_blocks - 1),
        reduce: {hidden_state, hidden_states, attentions} do
      {hidden_state, hidden_states, attentions} ->
        {hidden_state, attention} = encoder_block(hidden_state, config, name: join(name, idx))

        {
          hidden_state,
          Layers.append(hidden_states, hidden_state),
          Layers.append(attentions, attention)
        }
    end
  end

  defp encoder_block(hidden_state, config, opts) do
    name = opts[:name]

    {attention_output, attention} =
      hidden_state
      |> Axon.layer_norm(
        channel_index: 2,
        epsilon: config.layer_norm_epsilon,
        name: join(name, "layernorm_before")
      )
      |> attention(config, name: join(name, "attention"))

    attention_output = Axon.add(attention_output, hidden_state)

    output =
      attention_output
      |> Axon.layer_norm(
        channel_index: 2,
        epsilon: config.layer_norm_epsilon,
        name: join(name, "layernorm_after")
      )
      |> intermediate(config, name: join(name, "intermediate"))
      |> output(attention_output, config, name: join(name, "output"))

    {output, attention}
  end

  defp attention(hidden_state, config, opts) do
    name = opts[:name]

    {attention_output, attention} =
      self_attention(hidden_state, config, name: join(name, "attention"))

    attention_output =
      self_output(attention_output, hidden_state, config, name: join(name, "output"))

    {attention_output, attention}
  end

  defp self_attention(hidden_state, config, opts) do
    name = opts[:name]

    num_heads = config.num_attention_heads

    query =
      hidden_state
      |> Axon.dense(config.hidden_size,
        kernel_initializer: kernel_initializer(config),
        use_bias: config.use_qkv_bias,
        name: join(name, "query")
      )
      |> Layers.split_heads(num_heads)

    key =
      hidden_state
      |> Axon.dense(config.hidden_size,
        kernel_initializer: kernel_initializer(config),
        use_bias: config.use_qkv_bias,
        name: join(name, "key")
      )
      |> Layers.split_heads(num_heads)

    value =
      hidden_state
      |> Axon.dense(config.hidden_size,
        kernel_initializer: kernel_initializer(config),
        use_bias: config.use_qkv_bias,
        name: join(name, "value")
      )
      |> Layers.split_heads(num_heads)

    attention_bias = Axon.constant(Nx.tensor(0))

    attention_weights =
      Layers.attention_weights(query, key, attention_bias)
      |> Axon.dropout(rate: config.attention_dropout_rate, name: join(name, "dropout"))

    attention_output =
      attention_weights
      |> Layers.attention_output(value)
      |> Layers.flatten_trailing()

    {attention_output, attention_weights}
  end

  defp self_output(hidden_state, _input_tensor, config, opts) do
    name = opts[:name]

    hidden_state
    |> Axon.dense(config.hidden_size,
      kernel_initializer: kernel_initializer(config),
      name: join(name, "dense")
    )
    |> Axon.dropout(rate: config.dropout_rate, name: join(name, "dropout"))
  end

  defp intermediate(hidden_state, config, opts) do
    name = opts[:name]

    hidden_state
    |> Axon.dense(config.intermediate_size,
      kernel_initializer: kernel_initializer(config),
      name: join(name, "dense")
    )
    |> Axon.activation(config.activation)
  end

  defp output(hidden_state, attention_output, config, opts) do
    name = opts[:name]

    hidden_state
    |> Axon.dense(config.hidden_size,
      kernel_initializer: kernel_initializer(config),
      name: join(name, "dense")
    )
    |> Axon.dropout(rate: config.dropout_rate, name: join(name, "dropout"))
    |> Axon.add(attention_output, name: join(name, "residual"))
  end

  defp pooler(hidden_state, config, opts) do
    name = opts[:name]

    hidden_state
    |> Layers.take_token(index: 0, axis: 1, name: join(name, "head"))
    |> Axon.dense(config.hidden_size,
      kernel_initializer: kernel_initializer(config),
      name: join(name, "dense")
    )
    |> Axon.tanh(name: join(name, "tanh"))
  end

  defp kernel_initializer(config) do
    Axon.Initializers.normal(scale: config.initializer_scale)
  end

  defimpl Bumblebee.HuggingFace.Transformers.Config do
    def load(config, data) do
      import Shared.Converters

      opts =
        convert!(data,
          image_size: {"image_size", number()},
          num_channels: {"num_channels", number()},
          patch_size: {"patch_size", number()},
          hidden_size: {"hidden_size", number()},
          num_blocks: {"num_hidden_layers", number()},
          num_attention_heads: {"num_attention_heads", number()},
          intermediate_size: {"intermediate_size", number()},
          activation: {"hidden_act", atom()},
          use_qkv_bias: {"qkv_bias", boolean()},
          dropout_rate: {"hidden_dropout_prob", number()},
          attention_dropout_rate: {"attention_probs_dropout_prob", number()},
          layer_norm_epsilon: {"layer_norm_eps", number()},
          initializer_scale: {"initializer_range", number()}
        ) ++ Shared.common_options_from_transformers(data, config)

      @for.config(config, opts)
    end
  end
end
