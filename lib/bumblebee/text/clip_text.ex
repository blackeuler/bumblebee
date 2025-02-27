defmodule Bumblebee.Text.ClipText do
  alias Bumblebee.Shared

  options =
    [
      vocab_size: [
        default: 49408,
        doc: """
        the vocabulary size of the token embedding. This corresponds to the number of distinct
        tokens that can be represented in model input and output
        """
      ],
      max_positions: [
        default: 77,
        doc: """
        the vocabulary size of the position embedding. This corresponds to the maximum sequence
        length that this model can process. Typically this is set to a large value just in case,
        such as 512, 1024 or 2048
        """
      ],
      hidden_size: [
        default: 512,
        doc: "the dimensionality of hidden layers"
      ],
      num_blocks: [
        default: 12,
        doc: "the number of Transformer blocks in the encoder"
      ],
      num_attention_heads: [
        default: 8,
        doc: "the number of attention heads for each attention layer in the encoder"
      ],
      intermediate_size: [
        default: 2048,
        doc:
          "the dimensionality of the intermediate layer in the transformer feed-forward network (FFN) in the encoder"
      ],
      activation: [
        default: :quick_gelu,
        doc: "the activation function"
      ],
      attention_dropout_rate: [
        default: 0.0,
        doc: "the dropout rate for attention weights"
      ],
      layer_norm_epsilon: [
        default: 1.0e-5,
        doc: "the epsilon used by the layer normalization layers"
      ]
    ] ++
      Shared.common_options([
        :output_hidden_states,
        :output_attentions,
        :num_labels,
        :id_to_label
      ]) ++ Shared.token_options(pad_token_id: 1, bos_token_id: 0, eos_token_id: 2)

  @moduledoc """
  The CLIP model for text encoding.

  ## Architectures

    * `:base` - the base text model

  ## Inputs

    * `"input_ids"` - `{batch_size, sequence_length}`

      Indices of input sequence tokens in the vocabulary.

    * `"attention_mask"` - `{batch_size, sequence_length}`

      Mask indicating which tokens to attend to. This is used to ignore
      padding tokens, which are added when processing a batch of sequences
      with different length.


    * `"position_ids"` - `{batch_size, sequence_length}`

      Indices of positions of each input sequence tokens in the position
      embeddings.

  ## Configuration

  #{Shared.options_doc(options)}
  """

  defstruct [architecture: :base] ++ Shared.option_defaults(options)

  @behaviour Bumblebee.ModelSpec
  @behaviour Bumblebee.Configurable

  import Bumblebee.Utils.Model, only: [join: 2]

  alias Bumblebee.Layers

  @impl true
  def architectures(), do: [:base]

  @impl true
  def config(spec, opts \\ []) do
    spec
    |> Shared.put_config_attrs(opts)
    |> Shared.validate_label_options()
  end

  @impl true
  def input_template(_spec) do
    %{
      "input_ids" => Nx.template({1, 1}, :s64)
    }
  end

  @impl true
  def model(%__MODULE__{architecture: :base} = spec) do
    inputs = inputs()

    inputs
    |> core(spec)
    |> Layers.output()
  end

  defp inputs() do
    shape = {nil, nil}

    Bumblebee.Utils.Model.inputs_to_map([
      Axon.input("input_ids", shape: shape),
      Axon.input("attention_mask", optional: true, shape: shape),
      Axon.input("position_ids", optional: true, shape: shape)
    ])
  end

  defp core(inputs, spec) do
    input_ids = inputs["input_ids"]

    embeddings = embedder(input_ids, inputs["position_ids"], spec, name: "embedder")
    encoder_outputs = encoder(embeddings, inputs["attention_mask"], spec, name: "encoder")

    hidden_state =
      Axon.layer_norm(encoder_outputs.hidden_state, epsilon: spec.layer_norm_epsilon, name: "norm")

    pooled_state =
      Axon.layer(
        fn hidden_state, input_ids, _opts ->
          eos_idx = Nx.argmax(input_ids, axis: -1)
          Bumblebee.Utils.Nx.batched_take(hidden_state, eos_idx)
        end,
        [hidden_state, input_ids]
      )

    %{
      hidden_state: hidden_state,
      pooled_state: pooled_state,
      hidden_states: encoder_outputs.hidden_states,
      attentions: encoder_outputs.attentions
    }
  end

  defp embedder(input_ids, position_ids, spec, opts) do
    name = opts[:name]

    position_ids =
      Layers.default position_ids do
        Layers.default_position_ids(input_ids)
      end

    input_embeddings =
      Axon.embedding(input_ids, spec.vocab_size, spec.hidden_size,
        kernel_initializer: Axon.Initializers.normal(),
        name: join(name, "token_embedding")
      )

    position_embeddings =
      Axon.embedding(position_ids, spec.max_positions, spec.hidden_size,
        kernel_initializer: Axon.Initializers.normal(),
        name: join(name, "position_embedding")
      )

    Axon.add(input_embeddings, position_embeddings)
  end

  defp encoder(embeddings, attention_mask, spec, opts) do
    name = opts[:name]

    Layers.Transformer.blocks(embeddings,
      attention_mask: attention_mask,
      causal?: true,
      num_blocks: spec.num_blocks,
      num_attention_heads: spec.num_attention_heads,
      hidden_size: spec.hidden_size,
      kernel_initializer: Axon.Initializers.normal(scale: 0.01),
      dropout_rate: 0.0,
      attention_dropout_rate: spec.attention_dropout_rate,
      layer_norm_epsilon: spec.layer_norm_epsilon,
      norm_placement: :first,
      ffn: [
        intermediate_size: spec.intermediate_size,
        activation: spec.activation
      ],
      output_hidden_states: spec.output_hidden_states,
      output_attentions: spec.output_attentions,
      name: join(name, "blocks")
    )
  end

  defimpl Bumblebee.HuggingFace.Transformers.Config do
    # Support loading from the entire Clip configuration
    def load(spec, %{"model_type" => "clip", "text_config" => data}) do
      load(spec, data)
    end

    def load(spec, data) do
      import Shared.Converters

      opts =
        convert!(data,
          vocab_size: {"vocab_size", number()},
          max_positions: {"max_position_embeddings", number()},
          hidden_size: {"hidden_size", number()},
          num_blocks: {"num_hidden_layers", number()},
          num_attention_heads: {"num_attention_heads", number()},
          intermediate_size: {"intermediate_size", number()},
          activation: {"hidden_act", atom()},
          attention_dropout_rate: {"attention_dropout", number()},
          layer_norm_epsilon: {"layer_norm_eps", number()}
        ) ++ Shared.common_options_from_transformers(data, spec)

      @for.config(spec, opts)
    end
  end

  defimpl Bumblebee.HuggingFace.Transformers.Model do
    def params_mapping(_spec) do
      %{
        "embedder.token_embedding" => "text_model.embeddings.token_embedding",
        "embedder.position_embedding" => "text_model.embeddings.position_embedding",
        "encoder.blocks.{n}.self_attention.query" =>
          "text_model.encoder.layers.{n}.self_attn.q_proj",
        "encoder.blocks.{n}.self_attention.key" =>
          "text_model.encoder.layers.{n}.self_attn.k_proj",
        "encoder.blocks.{n}.self_attention.value" =>
          "text_model.encoder.layers.{n}.self_attn.v_proj",
        "encoder.blocks.{n}.self_attention.output" =>
          "text_model.encoder.layers.{n}.self_attn.out_proj",
        "encoder.blocks.{n}.self_attention_norm" => "text_model.encoder.layers.{n}.layer_norm1",
        "encoder.blocks.{n}.ffn.intermediate" => "text_model.encoder.layers.{n}.mlp.fc1",
        "encoder.blocks.{n}.ffn.output" => "text_model.encoder.layers.{n}.mlp.fc2",
        "encoder.blocks.{n}.output_norm" => "text_model.encoder.layers.{n}.layer_norm2",
        "norm" => "text_model.final_layer_norm"
      }
    end
  end
end
