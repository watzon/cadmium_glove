require "./workers"

module Cadmium::Glove
  class Model

    property epochs : Int32

    property num_components : Int32

    property max_count : Int32

    property alpha : Float64

    property learning_rate : Float64

    property threads : Int32

    property token_index : Hash(String, Int32)

    property token_pairs : Array(TokenPair)

    property cooc_matrix : Apatite::Matrix(Float64)

    property word_vec : Apatite::Matrix(Float64)

    property word_biases : Array(Float64)

    setter corpus : Corpus?

    # Creates a new `Glove::Model` instance.
    def initialize(
      @max_count = 100,
      @learning_rate = 0.05,
      @alpha = 0.75,
      @num_components = 30,
      @epochs = 5,
      @threads = 4
    )
      @token_index = {} of String => Int32
      @token_pairs = [] of TokenPair
      @cooc_matrix = Apatite::Matrix(Float64).empty(0, 0)
      @word_vec = Apatite::Matrix(Float64).empty(0, 0)
      @word_biases = Array(Float64).new
    end

    # Fit a String or `Glove::Corpus` instance and build a co-occurrence matrix.
    def fit(text, **options)
      fit_corpus(text, **options)
      build_cooc_matrix
      build_word_vectors
      self
    end

    # Train the model. `#fit` must be called prior to this.
    def train
      start_time = Time.now
      puts "Started training at " + start_time.to_s("%X")
      train_in_epochs(matrix_nnz)
      finish_time = Time.now
      puts "Finished training at " + finish_time.to_s("%X")
      span = finish_time - start_time
      puts "Time elapsed #{span.total_minutes.to_i} minutes and #{span.seconds} seconds"
      self
    end

    def corpus
      @corpus.not_nil!
    rescue
      raise "Corpus is `nil`. Please run `Model#fit` first to generate one."
    end

    # Save trained data to files
    def save(corpus_file, cooc_file, vec_file, bias_file)
      corpus_dump = corpus.to_json
      cooc_dump = cooc_matrix.to_json
      word_vec_dump = word_vec.to_json
      word_bias_dump = word_biases.to_json

      File.write(corpus_file, corpus_dump)
      File.write(cooc_file, cooc_dump)
      File.write(vec_file, word_vec_dump)
      File.write(bias_file, word_bias_dump)
    end

    # Loads training data from already existing files.
    def load(corpus_file, cooc_file, vec_file, bias_file)
      corpus_data = File.read(corpus_file)
      @corpus = Corpus.from_json(corpus_data)

      @token_index = corpus.index
      @token_pairs = corpus.pairs

      cooc_matrix_data = File.read(cooc_file)
      @cooc_matrix = Apatite::Matrix.from_json(cooc_matrix_data)

      word_vec_data = File.read(vec_file)
      @word_vec    = Apatite::Matrix.from_json(word_vec_data)

      word_bias_data = File.read(bias_file)
      @word_biases = Array(Float64).from_json(word_bias_data)

      self
    end

    # TODO: Generate a graph of the word vector matrix
    def visualize
      raise "Not implemented"
    end

    # Get a word that relates to `target` like `word1` relates to `word2`.
    #
    # Example:
    # ```
    # model.analogy_words("quantum", "physics", "atom")
    # # => [{"electron", 0.98583}, {"energi", 0.98151}, {"photon",0.96650}]
    # ```
    def analogy_words(word1, word2, target, num = 3, accuracy = 1e-4)
      return [] of Tuple(String, Float64) unless word1 && word2 && target

      distance = cosine(vector(word1), vector(word2))

      vector_distance(target).reject do |item|
        diff = item[1].to_f.abs - distance
        diff.abs < accuracy
      end.first(num)
    end

    # Get most similar words to `word`.
    def most_similar(word, num = 3)
      vector_distance(word).first(num)
    end

    # Perform train iterations
    private def train_in_epochs(indices)
      1.upto(@epochs) do |epoch|
        shuffled = indices.shuffle
        @word_vec, @word_biases = Workers::TrainingWorker.new(self, shuffled).run
      end
    end

    # Builds the corpus and sets @token_index and @token_pairs
    private def fit_corpus(text, **options)
      @corpus = if text.is_a?(Corpus)
          text
      else
        Corpus.build(text, **options)
      end

      @token_index = corpus.index
      @token_pairs = corpus.pairs
    end

    # Create initial values for @word_vec and @word_biases
    private def build_word_vectors
      cols = @token_index.size
      @word_vec = Apatite::Matrix.build(cols, @num_components) { rand(10.0) }
      @word_biases = Array(Float64).new(cols, nil)
    end

    # Builds the co-occurrence matrix
    private def build_cooc_matrix
      @cooc_matrix = Workers::CooccurrenceWorker.new(self).run
    end

    # Array of all non-zero (both row and col) value coordinates in
    # the @cooc_matrix.
    private def matrix_nnz
      entries = [] of Tuple(Int32, Int32)
      cooc_matrix.column_vectors.each_with_index do |col, col_idx|
        col.each_with_index do |row, row_idx|
          value = cooc_matrix[row_idx, col_idx]
          entries << {row_idx, col_idx} unless value.zero?
        end
      end
      entries
    end

    # Find the vector row of @word_vec for a given word.
    private def vector(word)
      return nil unless word_index = token_index[word]?
      word_vec.row(word_index)
    end

    # Calculates the cosine distance of all the words in the vocabulary
    # against a given word. Results are then sorted in DESC order.
    private def vector_distance(word)
      return [] of Tuple(String, Float64) unless word_vector = vector(word)

      token_index.map_with_index do |(token, count), idx|
        next if token == word # NOTE: Might not be right
        {token, Apatite.cosine(word_vector, word_vec.row(idx))}
      end.compact.sort { |a, b| b[1] <=> a[1] }
    end

    private def cosine(vector1, vector2)
      return 0 if vector1.nil? || vector2.nil?
      vector1.dot(vector2) / (vector1.norm * vector2.norm)
    end
  end
end
