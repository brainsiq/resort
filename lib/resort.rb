# # Resort
#
# A tool that allows any ActiveRecord model to be sorted.
#
# Unlike most Rails sorting plugins (acts_as_list, etc), Resort is based
# on linked lists rather than absolute position fields.
#
# @example Using Resort in an ActiveRecord model
#     # In the migration
#     create_table :products do |t|
#       t.text       :name
#       t.references :next
#       t.boolean    :first
#     end
#
#     # Model
#     class Product < ActiveRecord::Base
#       resort!
#
#       # A sortable model must implement #siblings method, which should
#       # return and ActiveRecord::Relation with all the models to be
#       # considered as `peers` in the list representing the sorted
#       # products, i.e. its siblings.
#       def siblings
#         self.class.scoped
#       end
#     end
#
#     product = Product.create(:name => 'Bread')
#     product.first? # => true
#
#     another_product = Product.create(:name => 'Milk')
#     yet_another_product = Product.create(:name => 'Salami')
#
#     yet_another_product.append_to(product)
#
#     Product.ordered.map(&:name)
#     # => ['Bread', 'Salami', 'Milk']
module Resort
  # The module encapsulating all the Resort functionality.
  #
  # @todo Refactor into a more OO solution, maybe implementing a LinkedList
  #   object.
  module Sortable
    class << self
      # When included, extends the includer with {ClassMethods}, and includes
      # {InstanceMethods} in it.
      #
      # It also establishes the required relationships. It is necessary that
      # the includer table has the following database columns:
      #
      #     t.references :next
      #     t.boolean :first
      #
      # @param [ActiveRecord::Base] base the includer `ActiveRecord` model.
      def included(base)
        base.extend ClassMethods
        base.send :include, InstanceMethods

        base.has_one :previous, :class_name => base.name, :foreign_key => 'next_id', :inverse_of => :next
        base.belongs_to :next, :class_name => base.name, :inverse_of => :previous

        base.after_create :include_in_list!
        base.after_destroy :delete_from_list
      end
    end

    # Class methods to be used from the model class.
    module ClassMethods
      # Returns the first element of the list.
      #
      # @return [ActiveRecord::Base] the first element of the list.
      def first_in_order
        where(:first => true).first
      end
      
      # Returns eager-loaded Components in order.
      #
      # OPTIMIZE: Avoid creating as many hashes.
      # @return [Array<ActiveRecord::Base>] the ordered elements
      def ordered
        ordered_elements = []
        elements = {}

        scoped.each do |element|
          if element.first?
            ordered_elements << element
          else
            elements[element.id] = element
          end
        end

        elements.length.times do
          ordered_elements << elements[ordered_elements.last.next_id]
        end
        ordered_elements
      end
    end

    # Instance methods to use.
    module InstanceMethods

      # Default definition of siblings, i.e. every instance of the model.
      #
      # Can be overriden to specify a different scope for the siblings.
      # For example, if we wanted to limit a products tree inside a ProductLine
      # scope, we would do the following:
      #
      #     class Product < ActiveRecord::Base
      #       belongs_to :product_line
      #
      #       resort!
      #
      #       def siblings
      #         self.product_line.products
      #       end
      #
      # This way, every product line is an independent tree of sortable
      # products.
      #
      # @return [ActiveRecord::Relation] the element's siblings relation.
      def siblings
        self.class.scoped
      end
      # Includes the object in the linked list.
      #
      # If there are no other objects, it prepends the object so that it is
      # in the first position. Otherwise, it appends it to the end of the
      # empty list.
      def include_in_list!
        _siblings.count > 0 ? push\
                            : prepend
      end

      # Puts the object in the first position of the list.
      def prepend
        return if first?

        if _siblings.count > 0
          delete_from_list
          _siblings.where(:first => true).first.append_to(self)
        end

        self.update_attribute(:first, true)
      end

      # Puts the object in the last position of the list.
      def push
        return if last?
        last_element = _siblings.where(:next_id => nil).first
        self.append_to(last_element)
      end

      # Puts the object right after another object in the list.
      def append_to(another)
        if self.next
          delete_from_list
        elsif last?
          self.previous.update_attribute(:next_id, nil)
          self.previous = nil
        end

        self.update_attribute(:next_id, another.next_id)
        another.update_attribute(:next_id, self.id)
      end

      private

      def delete_from_list
        if first? && self.next
          self.update_attribute(:first, nil) unless frozen?
          self.next.first = true 
          self.next.previous = nil
          self.next.save!
        elsif self.previous
          previous.next = self.next
          previous.save!
          self.update_attribute(:next_id, nil) unless frozen?
        end
      end

      def last?
        self.previous && !self.next
      end

      def _siblings
        table = self.class.arel_table
        siblings.where(table[:id].not_eq(self.id))
      end
    end
  end
  # Helper class methods to be injected into ActiveRecord::Base class.
  # They will be available to every model.
  module ClassMethods
    # Helper class method to include Resort::Sortable in an ActiveRecord
    # model.
    def resort!
      include Sortable
    end
  end
end

require 'active_record' unless defined?(ActiveRecord)
ActiveRecord::Base.extend Resort::ClassMethods
